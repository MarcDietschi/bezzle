import AppKit
import CoreText

/// Words along curves on the canvas (see `TextCurve`).
///
/// - A selected text shows the line it sits on, running on past its ends to a bead at each. A
///   bead swung round the middle of the words bends them: they go a quarter of the angle it is
///   swung through round a circle, so straight below the middle they close into a ring, and
///   above it they sag. Straight, a half circle and a ring catch, with a tick of the trackpad.
/// - A text dragged and held a moment on a shape's edge catches on it: a line runs out along the
///   edge as far as the words will reach, and they jump onto it, letter by letter from the
///   pointer out. Still held, they slide along after the pointer, keep to the side of the edge
///   the pointer is on, and always turn to read upright. Dragged clear, they let go again.
/// - A text riding a shape, dragged, slides along it the same way; pulled well clear, it comes off,
///   straight again.
/// - Whenever a text's letters change places other than by moving the whole text, as it is bent,
///   put on a shape, taken off one, typed into or undone, each letter springs to its new place.
final class CurveTool {
    private let store: DocumentStore
    var redraw: () -> Void = {}
    private var deviceScale: CGFloat = 2

    init(store: DocumentStore) {
        self.store = store
    }

    private var zoom: CGFloat { store.viewport.zoom }
    private func view(_ p: CGPoint) -> CGPoint { store.viewport.toView(p) }
    private func canvas(_ v: CGPoint) -> CGPoint { store.viewport.toCanvas(v) }

    /// How long a text has to rest on an edge to catch on it.
    private static let rest: CFTimeInterval = 0.42
    /// How far the pointer may wander on screen and still be resting.
    private static let wander: CGFloat = 6
    /// How near an edge, on screen, the pointer has to be for the text to catch on it.
    private static let band: CGFloat = 12
    /// How far past its ends, on screen, a text's line runs out to its beads.
    private static let reach: CGFloat = 22
    private static let stops: [Double] = [-1, -0.5, 0, 0.5, 1]

    // MARK: - Time

    private var lastFrame: CFTimeInterval = 0
    private var dt: Double = 1.0 / 120

    private func tick() {
        let now = CACurrentMediaTime()
        dt = lastFrame == 0 ? 1.0 / 120 : min(max(now - lastFrame, 1.0 / 240), 1.0 / 20)
        lastFrame = now
    }

    /// Whether the canvas should be drawn again next frame, for something on its way.
    var animating: Bool {
        if tracks.values.contains(where: \.moving) { return true }
        if let h = hold, h.over != nil, h.ride == nil { return true }
        return glow.map { CACurrentMediaTime() - $0.born < 0.9 } == true
    }

    // MARK: - Geometry

    /// From a layer's own coordinates, its frame's top left at zero, to the canvas.
    static func toCanvas(_ node: Node, origin o: CGPoint) -> CGAffineTransform {
        CGAffineTransform(translationX: -node.frame.width / 2, y: -node.frame.height / 2)
            .concatenating(CGAffineTransform(rotationAngle: Geometry.radians(node.rotation)))
            .concatenating(CGAffineTransform(translationX: o.x + node.frame.midX, y: o.y + node.frame.midY))
    }

    private func toCanvas(_ node: Node, in doc: BezzleDocument) -> CGAffineTransform {
        Self.toCanvas(node, origin: doc.parentOrigin(of: node.id))
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

    // MARK: - Bending by the beads

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
        guard store.tool == .select, store.editingText == nil, store.editingPath == nil, store.editingPicture == nil, store.building == nil,
              store.selection.count == 1, let node = store.node(store.selection[0]), node.kind == .text, !node.locked, !node.rides,
              node.transform3D == nil, !store.doc.ancestors(of: node.id).contains(where: \.locked),
              node.frame.width * zoom >= 14, !(node.text ?? "").isEmpty else { return nil }
        let t = toCanvas(node, in: store.doc)
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

    var dragging: Bool { bending != nil }

    /// A press on a bead begins bending; anything else is left to the canvas.
    func down(at v: CGPoint, event: NSEvent) -> Bool {
        guard event.clickCount == 1, !event.modifierFlags.contains(.command), let b = beads() else { return false }
        guard let i = b.beads.indices.min(by: { hypot(view(b.beads[$0]).x - v.x, view(b.beads[$0]).y - v.y) < hypot(view(b.beads[$1]).x - v.x, view(b.beads[$1]).y - v.y) }),
              hypot(view(b.beads[i]).x - v.x, view(b.beads[i]).y - v.y) <= 9 else { return false }
        store.beginGesture()
        bending = Bending(id: b.id, apex: b.apex, turn: b.turn, atEnd: i == 1, last: b.bend, caught: Self.stops.first { abs($0 - b.bend) < 0.0001 })
        NSCursor.closedHand.set()
        return true
    }

    func drag(to v: CGPoint, flags: NSEvent.ModifierFlags) {
        guard var b = bending else { return }
        let p = canvas(v)
        let q = Geometry.rotate(CGPoint(x: p.x - b.apex.x, y: p.y - b.apex.y), by: -b.turn)
        guard hypot(q.x, q.y) * zoom > 6 else { return }
        // Swung down from level, the end arches the words; straight down, they are a ring.
        let phi = min(max(atan2(q.y, b.atEnd ? q.x : -q.x), -.pi / 2), .pi / 2)
        var bend = Double(phi / (.pi / 2))
        let near = flags.contains(.command) ? nil : Self.stops.first { abs($0 - bend) < 0.03 }
        if let near {
            bend = near
            if b.caught != near { NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now) }
        }
        b.caught = near
        bend = (bend * 1000).rounded() / 1000
        if bend != b.last {
            b.last = bend
            let id = b.id
            store.edit(DocumentStore.bending) { doc in doc.update(id) { $0.bend(to: bend) } }
        }
        bending = b
        if let r = store.doc.absoluteFrame(of: b.id) {
            let degrees = Int((abs(bend) * 360).rounded())
            store.measurement = (bend == 0 ? "0°" : "\(bend < 0 ? "−" : "")\(degrees)°", r)
        }
        redraw()
    }

    func up() {
        guard let b = bending else { return }
        bending = nil
        store.endGesture(b.last == 0 ? DocumentStore.straightening : DocumentStore.bending)
        store.measurement = nil
        redraw()
    }

    // MARK: - Catching on an edge, and sliding along it

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
        /// The design the moment before it caught on, to go back to if it is dragged off; nil
        /// when it rode before the drag began.
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
        var since: CFTimeInterval = 0
        var at: CGPoint = .zero
        var ride: Ride?
        /// Shapes left again in this drag, which it does not catch on again.
        var declined: Set<UUID> = []
        var torn = false
        /// Where the pointer has lately been on the canvas, latest last: the side of an edge it
        /// came from is where the words go.
        var trail: [CGPoint] = []
    }

    private var hold: Hold?
    private var waiting: Timer?
    private var glow: (path: CGPath, born: CFTimeInterval, out: Bool)?

    /// Whether resting or riding takes the drag, so that nothing else catches it, as a mask would.
    var claims: Bool { hold?.ride != nil || hold?.over != nil }

    enum Moved {
        /// Moved as anything is.
        case normal
        /// Slid along an edge: the canvas places nothing.
        case handled
        /// Torn off an edge: moved on from here, as if it had been this, at the drag's start.
        case restart(originals: [UUID: CGRect], bounds: CGRect)
    }

    /// Something being moved has been dragged to `v` on screen, from `start` on the canvas.
    func moving(_ ids: [UUID], from start: CGPoint, at v: CGPoint) -> Moved {
        tick()
        guard ids.count == 1, let id = ids.first, let node = store.node(id), node.kind == .text, !node.locked, store.inGesture else {
            if hold != nil { reset() }
            return .normal
        }
        let p = canvas(v)
        if hold?.text != id {
            hold = Hold(text: id)
            if node.rides, let shape = store.doc.parent(of: id)?.carrier, let edge = outline(of: shape.id, in: store.doc),
               let laid = CurvedText.laid(node) {
                // Held where it was pressed, however far along the words that was.
                let mid = middle(of: laid, total: laid.walk.total, width: CurvedText.width(of: node))
                let press = edge.walk.nearest(to: start).s
                hold?.ride = Ride(text: id, shape: shape.id, before: nil, offset: wrap(mid - press, edge.walk), width: CurvedText.width(of: node))
            }
        }
        guard var h = hold else { return .normal }
        h.trail.append(p)
        if h.trail.count > 40 { h.trail.removeFirst(h.trail.count - 40) }
        hold = h
        if var ride = h.ride {
            guard let edge = outline(of: ride.shape, in: store.doc), edge.walk.total > 0 else {
                hold?.ride = nil
                return .normal
            }
            let near = edge.walk.nearest(to: p)
            let size = (node.style?.size ?? 24) * zoom
            let tears = ride.before == nil ? max(64, size * 2.4) : max(40, size * 1.6)
            if near.distance * zoom > tears {
                h.declined.insert(ride.shape)
                h.ride = nil
                h.over = nil
                hold = h
                glow = (edge.path, CACurrentMediaTime(), true)
                fly(id, from: p)
                if let before = ride.before {
                    // Caught a moment ago: back as it was, straight under the pointer.
                    store.edit("Move") { $0 = before }
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
        let found = edgeUnder(p, for: id, declined: h.declined)
        if found?.shape != h.over?.shape || hypot(v.x - h.at.x, v.y - h.at.y) > Self.wander {
            h.over = found
            h.since = CACurrentMediaTime()
            h.at = v
            waiting?.invalidate()
            waiting = nil
            if found != nil {
                let timer = Timer(timeInterval: Self.rest, repeats: false) { [weak self] _ in
                    MainActor.assumeIsolated { self?.catchOn(at: v) }
                }
                RunLoop.main.add(timer, forMode: .common)
                waiting = timer
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
        if curve.reversed != node.curve?.reversed || curve.hangs != node.curve?.hangs { fly(node.id, from: canvas(hold?.at ?? .zero)) }
        ride.changed = true
        let id = node.id
        store.edit(DocumentStore.slidingText) { doc in doc.update(id) { $0.curve = curve } }
    }

    /// Takes a text that rode before the drag off its shape, straight under the pointer, and has
    /// the drag carry on with it from there.
    private func tearOff(_ id: UUID, at p: CGPoint, from start: CGPoint) -> Moved {
        store.edit(DocumentStore.takingOffPath) { doc in DocumentStore.takeOffPath([id], in: &doc) }
        guard let frame = store.doc.absoluteFrame(of: id) else { return .normal }
        hold?.torn = true
        NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
        // Its middle under the pointer, as at the drag's start it would have been at the press.
        let placed = CGRect(x: p.x - frame.width / 2, y: p.y - frame.height / 2, width: frame.width, height: frame.height)
        let original = placed.offsetBy(dx: start.x - p.x, dy: start.y - p.y)
        let o = store.doc.parentOrigin(of: id)
        store.edit("Move") { doc in doc.update(id) { $0.frame.origin = CGPoint(x: placed.minX - o.x, y: placed.minY - o.y) } }
        redraw()
        return .restart(originals: [id: original], bounds: original)
    }

    /// Resting has lasted: the text goes onto the edge, as one step with the drag.
    private func catchOn(at v: CGPoint) {
        waiting = nil
        guard var h = hold, h.ride == nil, let edge = h.over, store.inGesture, let node = store.node(h.text),
              let frame = store.doc.absoluteFrame(of: h.text) else { return }
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
        let before = store.doc
        fly(h.text, from: p)
        var made: UUID?
        let id = h.text
        store.edit(DocumentStore.riding) { doc in made = DocumentStore.ride(id, on: edge.shape, curve: curve, in: &doc) }
        guard made != nil, store.node(id)?.rides == true else { return }
        h.ride = Ride(text: id, shape: edge.shape, before: before, offset: 0, width: width)
        h.over = nil
        hold = h
        glow = (edge.path, CACurrentMediaTime(), false)
        store.guides = []
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
        redraw()
    }

    /// The edge of a shape a text dragged to `p` would catch on: the frontmost whose outline the
    /// pointer is on, of those it could ride.
    private func edgeUnder(_ p: CGPoint, for text: UUID, declined: Set<UUID>) -> Edge? {
        let doc = store.doc
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
                      DocumentStore.canRide(text, on: n.id, in: doc) else { continue }
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
                look(store.seenLayers(of: top), origin: top.frame.origin)
                if found == nil, top.frame.contains(p) { break }
            } else {
                look([top], origin: .zero)
            }
        }
        return found
    }

    /// The drag has been let go. Returns what it did, for the Edit menu, when it put a text on an
    /// edge, slid it along one or took it off; nil when it only moved.
    func released() -> LocalizedStringResource? {
        guard let h = hold else { return nil }
        reset()
        if let ride = h.ride {
            if ride.before != nil {
                NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
                return DocumentStore.riding
            }
            return ride.changed ? DocumentStore.slidingText : nil
        }
        return h.torn ? DocumentStore.takingOffPath : nil
    }

    func cancel() {
        guard hold != nil || bending != nil else { return }
        reset()
        bending = nil
        redraw()
    }

    private func reset() {
        waiting?.invalidate()
        waiting = nil
        hold = nil
    }

    // MARK: - Pointer

    func hover(_ v: CGPoint?) {
        var near = false
        var bead: Int?
        if let v, let b = beads() {
            let points = b.beads.map(view)
            bead = points.indices.first { hypot(points[$0].x - v.x, points[$0].y - v.y) <= 9 }
            if bead == nil, let id = store.selection.first, let frame = store.doc.absoluteFrame(of: id) {
                let box = store.viewport.toView(frame).insetBy(dx: -Self.reach - 12, dy: -18)
                near = box.contains(v)
            }
            near = near || bead != nil
        }
        if near != self.near || bead != hoveredBead {
            self.near = near
            hoveredBead = bead
            redraw()
        }
    }

    func cursor(at v: CGPoint) -> NSCursor? {
        if bending != nil { return .closedHand }
        // Words riding a shape, selected, slide along it under the hand.
        if store.tool == .select, store.editingText == nil, store.selection.count == 1, let node = store.node(store.selection[0]),
           node.rides, !node.locked {
            let o = store.doc.parentOrigin(of: node.id), p = canvas(v)
            if Geometry.contains(node, CGPoint(x: p.x - o.x, y: p.y - o.y), tolerance: 3 / zoom) { return .openHand }
        }
        guard let b = beads() else { return nil }
        let points = b.beads.map(view)
        return points.contains { hypot($0.x - v.x, $0.y - v.y) <= 9 } ? .openHand : nil
    }

    // MARK: - Letters on their way

    private struct Pose {
        var p: CGPoint
        var a: CGFloat
    }

    private struct Flier {
        let key: Int
        var letter: CurvedText.Letter
        var pose: Pose
        var target: Pose
        var v = CGPoint.zero
        var w: CGFloat = 0
        var wait: Double = 0
        var alpha: Double = 1
        var alphaTarget: Double = 1
        var settled = true
    }

    /// What a text's letters' places depend on, other than where the text is.
    private struct Signature: Equatable {
        let text: String?
        let spans: [TextSpan]?
        let style: TextStyle?
        let curve: TextCurve?
        let curvePath: String?
        let size: CGSize
        let rotation: Double
        let color: RGBA?
        let editing: Bool
    }

    private struct Track {
        var signature: Signature
        var origin: CGPoint
        var fliers: [Flier]
        var moving = false
        var stiff = false
        var opacity: Double
    }

    private var tracks: [UUID: Track] = [:]
    /// Texts whose next change flies letter by letter, from the letter nearest the point.
    private var flights: [UUID: CGPoint] = [:]

    /// Texts whose letters are springing to new places, which the canvas leaves to this.
    var flying: Set<UUID> { Set(tracks.lazy.filter(\.value.moving).map(\.key)) }

    /// Has a text's next change fly letter by letter, from the letter nearest `p`, even during a drag.
    func fly(_ id: UUID, from p: CGPoint? = nil) {
        flights[id] = p ?? CGPoint(x: CGFloat.nan, y: .nan)
    }

    /// The texts whose letters are watched: those selected or in what is selected, and any on their way.
    private func watched(_ doc: BezzleDocument) -> Set<UUID> {
        var ids = Set<UUID>()
        for id in store.selection.prefix(24) {
            guard let n = doc.node(id) else { continue }
            if n.kind == .text { ids.insert(id) }
            if n.isGroup { for c in n.children where c.kind == .text { ids.insert(c.id) } }
            if TextCurve.canCarry(n), let parent = doc.parent(of: id), parent.carrier?.id == id {
                for c in parent.children where c.rides { ids.insert(c.id) }
            }
        }
        if let id = store.editingText { ids.insert(id) }
        if let id = hold?.text { ids.insert(id) }
        ids.formUnion(flights.keys)
        ids.formUnion(tracks.lazy.filter(\.value.moving).map(\.key))
        return ids
    }

    /// Steps every text's letters on, before the canvas is drawn from `doc`, the design as it shows.
    func step(_ doc: BezzleDocument) {
        tick()
        let watched = watched(doc)
        // Those watched a moment ago too, so a text left as it changes, such as one typed into and
        // clicked away from, or undone, still flies.
        let ids = watched.union(tracks.keys)
        for id in ids {
            guard let node = doc.node(id), node.kind == .text, let origin = doc.absoluteFrame(of: id)?.origin else {
                tracks[id] = nil
                continue
            }
            let editing = store.editingText == id
            let signature = Signature(text: node.text, spans: node.spans, style: node.style, curve: node.curve, curvePath: node.curvePath,
                                      size: node.frame.size, rotation: node.rotation, color: node.letterColor, editing: editing)
            guard var track = tracks[id] else {
                let letters = targets(node, in: doc, editing: editing)
                tracks[id] = Track(signature: signature, origin: origin, fliers: letters.map { Flier(key: $0.key, letter: $0.letter, pose: $0.pose, target: $0.pose) },
                                   opacity: node.opacity)
                continue
            }
            track.opacity = node.opacity
            if track.signature == signature {
                if track.origin != origin {
                    // Moved as a whole: its letters go with it at once.
                    let dx = origin.x - track.origin.x, dy = origin.y - track.origin.y
                    for i in track.fliers.indices {
                        track.fliers[i].pose.p.x += dx
                        track.fliers[i].pose.p.y += dy
                        track.fliers[i].target.p.x += dx
                        track.fliers[i].target.p.y += dy
                    }
                    track.origin = origin
                }
            } else {
                let was = track.signature
                let letters = targets(node, in: doc, editing: editing)
                // Only letters going onto a curve, along it or off it fly: other changes to text show at once.
                let curved = was.curve != nil || signature.curve != nil
                let typing = editing && was.editing
                if !curved || typing {
                    track.fliers = letters.map { Flier(key: $0.key, letter: $0.letter, pose: $0.pose, target: $0.pose) }
                    track.moving = false
                } else {
                    let pivot = flights[id]
                    retarget(&track, to: letters, discrete: pivot != nil || !store.inGesture || was.editing != editing, pivot: pivot)
                }
                track.signature = signature
                track.origin = origin
            }
            if track.moving { integrate(&track) }
            // Left alone and at rest, it is no longer watched.
            tracks[id] = !track.moving && !watched.contains(id) ? nil : track
        }
        for id in flights.keys where ids.contains(id) { flights[id] = nil }
    }

    /// A text's letters where they belong now, on the canvas, each by the first of its letters in
    /// the words; while it is typed into, as it is typed into, straight.
    private func targets(_ node: Node, in doc: BezzleDocument, editing: Bool) -> [(key: Int, letter: CurvedText.Letter, pose: Pose)] {
        let o = doc.parentOrigin(of: node.id)
        var shown = node
        var origin = o
        var letters: [CurvedText.Letter]
        if editing, node.isCurved, let frame = doc.absoluteFrame(of: node.id) {
            let (flat, placed) = CurvedText.straight(node, frame: frame)
            shown = flat
            shown.frame = placed
            origin = .zero
            letters = CurvedText.straightLetters(shown)
        } else if let laid = CurvedText.laid(node) {
            letters = laid.letters
        } else {
            letters = CurvedText.straightLetters(node)
        }
        let t = Self.toCanvas(shown, origin: origin)
        return letters.map { letter in
            let m = letter.place.concatenating(t)
            let c = CGPoint(x: letter.advance / 2, y: (letter.ascent - letter.descent) / 2).applying(m)
            return (letter.characters.location, letter, Pose(p: c, a: atan2(m.b, m.a)))
        }
    }

    private func retarget(_ track: inout Track, to letters: [(key: Int, letter: CurvedText.Letter, pose: Pose)], discrete: Bool, pivot: CGPoint?) {
        var old: [Int: Flier] = [:]
        for f in track.fliers where f.alphaTarget > 0 { old[f.key] = f }
        var next: [Flier] = []
        // Letter by letter from the one nearest the pivot, or from the middle.
        var first = letters.count / 2
        if let pivot, !pivot.x.isNaN, !letters.isEmpty {
            first = letters.indices.min { hypot(letters[$0].pose.p.x - pivot.x, letters[$0].pose.p.y - pivot.y) < hypot(letters[$1].pose.p.x - pivot.x, letters[$1].pose.p.y - pivot.y) } ?? first
        }
        let gap = letters.count > 1 ? min(0.012, 0.22 / Double(letters.count)) : 0
        for (i, l) in letters.enumerated() {
            if var f = old.removeValue(forKey: l.key) {
                f.letter = l.letter
                var target = l.pose
                // The short way round.
                var turn = (target.a - f.pose.a).truncatingRemainder(dividingBy: 2 * .pi)
                if turn > .pi { turn -= 2 * .pi }
                if turn <= -.pi { turn += 2 * .pi }
                target.a = f.pose.a + turn
                f.target = target
                if discrete { f.wait = max(f.wait, Double(abs(i - first)) * gap) }
                f.settled = false
                next.append(f)
            } else {
                var f = Flier(key: l.key, letter: l.letter, pose: l.pose, target: l.pose)
                f.alpha = 0
                f.alphaTarget = 1
                f.settled = false
                f.wait = discrete ? Double(abs(i - first)) * gap : 0
                next.append(f)
            }
        }
        // Letters gone fade where they were.
        for (_, var f) in old {
            f.alphaTarget = 0
            f.target = f.pose
            f.settled = false
            next.append(f)
        }
        track.fliers = next
        track.stiff = !discrete
        track.moving = true
    }

    private func integrate(_ track: inout Track) {
        let k: CGFloat = track.stiff ? 1100 : 240
        let c: CGFloat = 2 * sqrt(k) * (track.stiff ? 0.9 : 0.64)
        let n = max(1, Int((dt / 0.004).rounded(.up)))
        let h = CGFloat(dt) / CGFloat(n)
        var moving = false
        for i in track.fliers.indices {
            var f = track.fliers[i]
            guard !f.settled else { continue }
            if f.wait > 0 {
                f.wait -= dt
                moving = true
                track.fliers[i] = f
                continue
            }
            for _ in 0..<n {
                f.v.x += (-k * (f.pose.p.x - f.target.p.x) - c * f.v.x) * h
                f.v.y += (-k * (f.pose.p.y - f.target.p.y) - c * f.v.y) * h
                f.w += (-k * (f.pose.a - f.target.a) - c * f.w) * h
                f.pose.p.x += f.v.x * h
                f.pose.p.y += f.v.y * h
                f.pose.a += f.w * h
            }
            f.alpha += (f.alphaTarget - f.alpha) * min(1, dt * 14)
            let still = 0.02 / zoom
            if abs(f.pose.p.x - f.target.p.x) < still, abs(f.pose.p.y - f.target.p.y) < still, abs(f.pose.a - f.target.a) < 0.0008,
               hypot(f.v.x, f.v.y) < 1 / zoom, abs(f.w) < 0.01, abs(f.alpha - f.alphaTarget) < 0.01 {
                f.pose = f.target
                f.v = .zero
                f.w = 0
                f.alpha = f.alphaTarget
                f.settled = true
            } else {
                moving = true
            }
            track.fliers[i] = f
        }
        track.fliers.removeAll { $0.settled && $0.alpha <= 0.001 }
        track.moving = moving
    }

    // MARK: - Drawing

    func draw(_ ctx: CGContext, scale: CGFloat) {
        deviceScale = scale
        drawFliers(ctx)
        drawEdge(ctx)
        drawBeads(ctx)
    }

    /// The letters springing to new places, over the design, which leaves those texts to this.
    private func drawFliers(_ ctx: CGContext) {
        let toView = CGAffineTransform(translationX: -store.viewport.origin.x, y: -store.viewport.origin.y)
            .concatenating(CGAffineTransform(scaleX: zoom, y: zoom))
        for track in tracks.values where track.moving {
            for f in track.fliers where f.alpha > 0.005 && f.letter.color.alpha > 0 {
                let l = f.letter
                let m = CGAffineTransform(translationX: -l.advance / 2, y: -(l.ascent - l.descent) / 2)
                    .concatenating(CGAffineTransform(scaleX: 1, y: -1))
                    .concatenating(CGAffineTransform(rotationAngle: f.pose.a))
                    .concatenating(CGAffineTransform(translationX: f.pose.p.x, y: f.pose.p.y))
                    .concatenating(toView)
                ctx.saveGState()
                ctx.concatenate(m)
                ctx.textMatrix = .identity
                ctx.setAlpha(CGFloat(f.alpha * track.opacity))
                ctx.setFillColor(l.color)
                var glyph = l.glyph, origin = CGPoint.zero
                CTFontDrawGlyphs(l.font, &glyph, &origin, 1, ctx)
                ctx.restoreGState()
            }
        }
    }

    /// An edge being rested on, a line running out along it as far as the words will reach, and
    /// the glow of one just caught on or left.
    private func drawEdge(_ ctx: CGContext) {
        let toView = CGAffineTransform(translationX: -store.viewport.origin.x, y: -store.viewport.origin.y)
            .concatenating(CGAffineTransform(scaleX: zoom, y: zoom))
        let now = CACurrentMediaTime()
        if let h = hold, h.ride == nil, let edge = h.over, let node = store.node(h.text) {
            let progress = min(max((now - h.since) / Self.rest, 0), 1)
            let eased = 1 - pow(1 - progress, 3)
            var t = toView
            if let shown = edge.path.copy(using: &t) { stroke(shown, glow: 0.35 * eased, width: 1.5, alpha: 0.45 * eased, ctx) }
            // As far each way as the words will reach.
            let half = CurvedText.width(of: node) / 2 * CGFloat(eased)
            let run = CGMutablePath()
            let steps = max(Int(half * 2 * zoom / 3), 2)
            for i in 0...steps {
                let s = edge.s - half + half * 2 * CGFloat(i) / CGFloat(steps)
                let q = edge.walk.at(edge.walk.closed ? s : min(max(s, 0), edge.walk.total)).point.applying(toView)
                if i == 0 { run.move(to: q) } else { run.addLine(to: q) }
            }
            stroke(run, glow: 0.8 * eased, width: 3, alpha: 0.9 * eased, ctx)
        }
        if let g = glow {
            let age = now - g.born
            if age > 0.9 {
                glow = nil
            } else {
                let k = g.out ? max(0, 1 - age / 0.5) * 0.6 : (age < 0.12 ? age / 0.12 : max(0, 1 - (age - 0.12) / 0.78))
                var t = toView
                if let shown = g.path.copy(using: &t) { stroke(shown, glow: k, width: 2, alpha: k * 0.8, ctx) }
            }
        }
    }

    private func stroke(_ path: CGPath, glow: Double, width: CGFloat, alpha: Double, _ ctx: CGContext) {
        guard alpha > 0.01 else { return }
        ctx.saveGState()
        ctx.setShadow(offset: .zero, blur: CGFloat(4 + 10 * glow) * deviceScale, color: CanvasInk.pencil.withAlphaComponent(min(0.95, glow)).cgColor)
        ctx.addPath(path)
        ctx.setStrokeColor(CanvasInk.pencil.withAlphaComponent(min(alpha, 1)).cgColor)
        ctx.setLineWidth(width)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.strokePath()
        ctx.restoreGState()
    }

    /// The line a selected text sits on and its two beads, while the pointer is near it.
    private func drawBeads(_ ctx: CGContext) {
        guard near || bending != nil, hold == nil, let b = beads() else { return }
        let toView = CGAffineTransform(translationX: -store.viewport.origin.x, y: -store.viewport.origin.y)
            .concatenating(CGAffineTransform(scaleX: zoom, y: zoom))
        var t = toView
        if let line = b.line.copy(using: &t) {
            ctx.saveGState()
            ctx.addPath(line)
            ctx.setStrokeColor(CanvasInk.pencil.withAlphaComponent(bending != nil ? 0.7 : 0.45).cgColor)
            ctx.setLineWidth(1)
            ctx.setLineCap(.round)
            ctx.strokePath()
            ctx.restoreGState()
        }
        for (i, bead) in b.beads.enumerated() {
            let lit = hoveredBead == i || (bending.map { $0.atEnd == (i == 1) } ?? false)
            let size: CGFloat = lit ? 9 : 7
            let rect = CGRect(x: view(bead).x - size / 2, y: view(bead).y - size / 2, width: size, height: size)
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: -0.5 * deviceScale), blur: 1.5 * deviceScale, color: NSColor.black.withAlphaComponent(0.18).cgColor)
            ctx.setFillColor(lit ? CanvasInk.pencil.cgColor : .white)
            ctx.fillEllipse(in: rect)
            ctx.restoreGState()
            ctx.setStrokeColor(CanvasInk.pencil.cgColor)
            ctx.setLineWidth(1)
            ctx.strokeEllipse(in: rect.insetBy(dx: 0.5, dy: 0.5))
        }
    }
}
