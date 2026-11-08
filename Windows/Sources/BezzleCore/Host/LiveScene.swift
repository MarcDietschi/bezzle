import Foundation

// What the canvas draws of the others in a shared design's live room, worked out as the Mac's
// Canvas/LiveMarks.swift and Views/LiveViews.swift work it out, each in their own pencil: where
// they look, as a soft pool of light on the table under the artboards; their hand, shaped like
// the tool they hold, gliding there as a hand would rather than stepping as the network does,
// with their name while they start moving, work, or come close; what they hold, outlined, with
// their initial on a flag; what they drag, moving as they drag it; what they changed, lit for a
// moment; a pencil loop where they shook their pointer. Those out of sight sit on the rim of the
// canvas, pointing their way; going to one flies the view there (the Mac's LiveCamera) and goes
// along with them until the view is moved by hand, crop marks in their pencil in the corners.
// The window draws it all from a `LiveScene`, in view points.

extension WindowsCore {
    /// Someone's hand, at a view point.
    public struct LiveHand: Sendable {
        public let id: UInt32
        public var at: CGPoint
        /// "text", "pen", "artboard", "rectangle", "ellipse", "line", or the arrow for anything else.
        public var tool: String
        public var pencil: UInt32
        public var alpha: Double
        /// How far their name shows beside it, 0 to 1, rising into place.
        public var tag: Double
        public var name: String
    }

    /// What someone holds: each layer's outline, and where their flag goes.
    public struct LiveHold: Sendable {
        public var outlines: [[CGPoint]]
        public var pencil: UInt32
        public var away: Bool
        public var flag: CGPoint
        public var initial: String
    }

    /// A layer someone just changed, lit in their pencil, fading (`fade` from 1 to 0).
    public struct LiveGlow: Sendable {
        public var outline: [CGPoint]
        public var pencil: UInt32
        public var fade: Double
    }

    /// A pencil loop: its points as far as it is drawn, each with the line's width there.
    public struct LiveLoop: Sendable {
        /// The same while the loop is the same, for what draws it to keep.
        public var key: String
        public var points: [CGPoint]
        public var widths: [Double]
        public var alpha: Double
        /// The person's pencil; nil for this computer's own, drawn in the pencil's blue.
        public var pencil: UInt32?
    }

    /// Where someone looks: a pool of light in their pencil, `rect` as wide as it reaches.
    public struct LiveLight: Sendable {
        public let id: UInt32
        public var rect: CGRect
        public var pencil: UInt32
        public var alpha: Double
    }

    /// Someone out of sight, on the rim of the canvas toward where they are.
    public struct LiveToken: Sendable {
        public let id: UInt32
        public var name: String
        public var initial: String
        /// The time where they are, when it is not the time here.
        public var clock: String?
        public var pencil: UInt32
        public var at: CGPoint
        /// Toward them, in radians from the right, the y axis down.
        public var angle: Double
        public var away: Bool
        public var working: Bool
        /// Their wink while it lasts, circling the token, about its middle.
        public var wink: LiveLoop?
    }

    /// Crop marks in the corners while going along with someone.
    public struct LiveCrop: Sendable {
        public var alpha: Double
        public var pencil: UInt32
        public var name: String
    }

    /// What the canvas draws of the live room this moment.
    public struct LiveScene: Sendable {
        public var lights: [LiveLight] = []
        public var hands: [LiveHand] = []
        public var holds: [LiveHold] = []
        public var glows: [LiveGlow] = []
        public var loops: [LiveLoop] = []
        public var tokens: [LiveToken] = []
        public var crop: LiveCrop?
        /// Whether anything is still easing, so the canvas keeps drawing.
        public var animating = false
        /// The design's layers (by their place among its artboards and loose layers) drawn with
        /// what others drag this frame, or to be drawn again now that it settled.
        public var moving: Set<Int> = []
        /// Pictures on their way in sight, developing where they are (`drawDeveloping`).
        public var developing: [LiveDeveloping] = []
        /// Whether those change every frame, clearing at first or coming into focus; otherwise
        /// only their grain moves, at `grainFrame`, a dozen times a second.
        public var developingMoves = false
        public var grainFrame = 0

        /// Nothing to draw.
        public init() {}
    }

    /// Draws with what the others drag this moment in the design: the artboards `body` draws
    /// show them where they have them, eased (the Mac's LiveMarks.overlaid).
    public static func drawingOthersMotion(_ body: () -> Void) {
        guard let shown = live?.marks.shown, let real = design else { body(); return }
        let version = designVersion
        design = shown
        body()
        design = real
        designVersion = version
    }
}

extension LiveTogether {
    /// Someone in the room by their place in it.
    func person(_ peer: UInt32) -> WindowsCore.LivePerson? { people.first { $0.id == peer } }

    /// The time where someone is, if it is not the time here (the Mac's zone(of:)), as a clock shows it.
    public func clock(of person: WindowsCore.LivePerson, at date: Date = Date()) -> String? {
        guard let id = person.timeZone, let zone = TimeZone(identifier: id),
              zone.secondsFromGMT(for: date) != TimeZone.current.secondsFromGMT(for: date) else { return nil }
        let format = DateFormatter()
        format.timeZone = zone
        format.dateStyle = .none
        format.timeStyle = .short
        return format.string(from: date)
    }

    /// The live room for a view of the canvas at `origin` (the canvas point at its top left),
    /// `zoom` and `size` (view points): what to draw this moment.
    public func scene(origin: CGPoint, zoom: Double, size: CGSize) -> WindowsCore.LiveScene {
        let vp = Viewport(origin: origin, zoom: CGFloat(zoom))
        let now = WindowsCore.now
        forget(before: now)
        marks.step(self, vp, now)
        var scene = WindowsCore.LiveScene()
        guard let real = WindowsCore.design else { return scene }
        settle(real, at: now)
        scene.moving = marks.overlay(real, self, vp)
        let doc = marks.shown ?? real
        let bounds = CGRect(origin: .zero, size: size)

        for (peer, rect) in marks.lights where peer != following {
            guard let person = person(peer), let alpha = marks.lightAlpha[peer], alpha > 0.01 else { continue }
            let r = vp.toView(rect)
            guard r.insetBy(dx: -r.width * 0.2, dy: -r.height * 0.2).intersects(bounds) else { continue }
            let w = max(r.width, 1) * 0.62, h = max(r.height, 1) * 0.62
            scene.lights.append(.init(id: peer, rect: CGRect(x: r.midX - w, y: r.midY - h, width: 2 * w, height: 2 * h), pencil: person.pencil, alpha: alpha))
        }
        for glow in glows {
            let t = (now - glow.time) / 1.4
            guard t < 1, let points = Self.outline(of: glow.id, in: doc, vp) else { continue }
            guard Self.box(points).insetBy(dx: -12, dy: -12).intersects(bounds) else { continue }
            scene.glows.append(.init(outline: points, pencil: glow.pencil, fade: pow(1 - max(t, 0), 2)))
        }
        for person in people {
            guard let p = presence[person.id], !p.selection.isEmpty else { continue }
            let outlines = p.selection.compactMap { Self.outline(of: $0, in: doc, vp) }
            guard !outlines.isEmpty else { continue }
            let box = outlines.map(Self.box).reduce(CGRect.null) { $0.union($1) }
            guard box.intersects(bounds.insetBy(dx: -20, dy: -20)) else { continue }
            scene.holds.append(.init(outlines: outlines, pencil: person.pencil, away: p.away, flag: CGPoint(x: box.minX, y: box.minY), initial: person.initial))
        }
        for wink in winks {
            let pencil: UInt32?
            if wink.by == Self.selfID { pencil = nil } else if let person = person(wink.by) { pencil = person.pencil } else { continue }
            let (drawn, alpha) = PencilLoop.shown(at: now - wink.time)
            guard drawn > 0, alpha > 0 else { continue }
            let c = vp.toView(wink.at)
            let seed = UInt64(bitPattern: Int64(wink.time * 1000))
            let all = PencilLoop.points(seed: seed, radius: 30)
            let last = Int(Double(all.count - 1) * drawn)
            guard last >= 1 else { continue }
            let points = all.prefix(last + 1).map { CGPoint(x: c.x + $0.x, y: c.y + $0.y) }
            let widths = (0...last).map { Double(PencilLoop.width(at: Double($0) / Double(all.count - 1), 2.6)) }
            scene.loops.append(.init(key: "\(seed)/\(last)/\(Int(c.x * 4))/\(Int(c.y * 4))", points: points, widths: widths, alpha: alpha, pencil: pencil))
        }
        for (peer, hand) in marks.hands.sorted(by: { $0.key < $1.key }) where hand.alpha > 0.01 {
            guard let person = person(peer) else { continue }
            let p = presence[peer]
            let at = vp.toView(hand.at)
            guard bounds.insetBy(dx: -40, dy: -40).contains(at) else { continue }
            scene.hands.append(.init(id: peer, at: at, tool: p?.doing == "typing" ? "text" : p?.tool ?? "select", pencil: person.pencil,
                                     alpha: hand.alpha, tag: hand.tag, name: person.name))
        }
        if marks.crop > 0.01, let person = marks.cropPerson {
            scene.crop = .init(alpha: marks.crop, pencil: person.pencil, name: person.name)
        }
        scene.tokens = tokens(vp, size, now)
        // Pictures on their way, developing where they are until they come and are in focus.
        onTheirWay.developed(before: now)
        scene.developing = onTheirWay.shown(doc, vp, size)
        scene.developingMoves = onTheirWay.all.values.contains { now - $0.since < PicturesOnTheirWay.clearing || $0.arrived != nil }
        scene.grainFrame = Int(now * 12)
        // Drawn on while any is on its way, so one comes into sight as the view moves to it.
        scene.animating = marks.isAnimating || camera.moving || !winks.isEmpty || !glows.isEmpty || !onTheirWay.all.isEmpty
        return scene
    }

    /// Those out of sight, on the rim toward them: on the line from the middle of the canvas to
    /// their pointer, or to the middle of what they look at; not while that is in sight, nor while
    /// they are followed (the Mac's LiveCompass).
    private func tokens(_ vp: Viewport, _ size: CGSize, _ now: Double) -> [WindowsCore.LiveToken] {
        var out: [WindowsCore.LiveToken] = []
        let bounds = CGRect(origin: .zero, size: size)
        for person in people where following != person.id {
            guard let p = presence[person.id] else { continue }
            let target = vp.toView(p.pointer ?? CGPoint(x: p.view.midX, y: p.view.midY))
            guard !bounds.insetBy(dx: 4, dy: 4).contains(target) else { continue }
            // Clear of the rulers along the top and left.
            let inner = CGRect(x: 40, y: 42, width: max(size.width - 70, 1), height: max(size.height - 72, 1))
            let c = CGPoint(x: inner.midX, y: inner.midY)
            let d = CGPoint(x: target.x - c.x, y: target.y - c.y)
            guard abs(d.x) > 0.001 || abs(d.y) > 0.001 else { continue }
            let s = min(abs(d.x) > 0.001 ? inner.width / 2 / abs(d.x) : .infinity, abs(d.y) > 0.001 ? inner.height / 2 / abs(d.y) : .infinity)
            var loop: WindowsCore.LiveLoop?
            if let wink = winks.last(where: { $0.by == person.id && now - $0.time < PencilLoop.lasts }) {
                let (drawn, alpha) = PencilLoop.shown(at: now - wink.time)
                let seed = UInt64(bitPattern: Int64(wink.time * 1000))
                let all = PencilLoop.points(seed: seed, radius: 21)
                let last = Int(Double(all.count - 1) * drawn)
                if last >= 1, alpha > 0 {
                    loop = .init(key: "\(seed)/\(last)", points: Array(all.prefix(last + 1)), widths: Array(repeating: 2, count: last + 1), alpha: alpha, pencil: person.pencil)
                }
            }
            out.append(.init(id: person.id, name: person.name, initial: person.initial, clock: clock(of: person), pencil: person.pencil,
                             at: CGPoint(x: c.x + d.x * s, y: c.y + d.y * s), angle: Double(atan2(d.y, d.x)),
                             away: person.away, working: person.doing != "looking" && !person.away, wink: loop))
        }
        return out
    }

    /// A layer's outline as it shows, in view points: a line's two ends, else its four corners.
    static func outline(of id: UUID, in doc: BezzleDocument, _ vp: Viewport) -> [CGPoint]? {
        guard let node = doc.node(id) else { return nil }
        let points: [CGPoint]
        if node.kind == .line {
            let (a, b) = node.lineEnds
            let c = CGPoint(x: node.frame.midX, y: node.frame.midY)
            points = [a, b].map { Perspective.shown(Geometry.rotated($0, about: c, by: node.rotation), of: node) }
        } else {
            points = Perspective.corners(of: node)
        }
        return points.map { vp.toView(doc.shown($0, inParentOf: id)) }
    }

    static func box(_ points: [CGPoint]) -> CGRect {
        let xs = points.map(\.x), ys = points.map(\.y)
        return CGRect(x: xs.min() ?? 0, y: ys.min() ?? 0, width: (xs.max() ?? 0) - (xs.min() ?? 0), height: (ys.max() ?? 0) - (ys.min() ?? 0))
    }

    // MARK: Going along

    /// Flies this canvas to where someone is looking, and keeps it there, going along with them
    /// until the view is moved by hand; going to someone already followed lets them go.
    public func go(to peer: UInt32, origin: CGPoint, zoom: Double, size: CGSize) {
        if following == peer {
            stopFollowing()
            return
        }
        guard let view = presence[peer]?.view else { return }
        following = peer
        camera.fly(from: Viewport(origin: origin, zoom: CGFloat(zoom)), to: Viewport(showing: view, in: size), size: size, follow: true)
        changed()
    }

    /// Flies to where someone winked last, keeping how wide they see.
    public func go(toWinkOf peer: UInt32, origin: CGPoint, zoom: Double, size: CGSize) {
        guard let wink = winks.last(where: { $0.by == peer }) else { go(to: peer, origin: origin, zoom: zoom, size: size); return }
        var target = Viewport(origin: origin, zoom: CGFloat(zoom))
        if let view = presence[peer]?.view { target = Viewport(showing: view, in: size) }
        target.origin = CGPoint(x: wink.at.x - size.width / 2 / target.zoom, y: wink.at.y - size.height / 2 / target.zoom)
        stopFollowing()
        camera.fly(from: Viewport(origin: origin, zoom: CGFloat(zoom)), to: target, size: size, follow: false)
        changed()
    }

    /// Whether someone winked a moment ago, for a click on their token to go there.
    public func winked(_ peer: UInt32) -> Bool {
        winks.contains { $0.by == peer && WindowsCore.now - $0.time < PencilLoop.lasts }
    }

    public func stopFollowing() {
        guard following != nil else { return }
        following = nil
        camera.letGo()
        changed()
    }

    /// The view the canvas has now, while it flies or goes along with someone: nil when nothing
    /// moves it. A view that is not the one given last was moved by hand, and lets them go.
    public func cameraStep(origin: CGPoint, zoom: Double, size: CGSize) -> (origin: CGPoint, zoom: Double)? {
        var followed: Viewport?
        if let peer = following, let view = presence[peer]?.view { followed = Viewport(showing: view, in: size) }
        guard let v = camera.step(Viewport(origin: origin, zoom: CGFloat(zoom)), size: size, followed: followed, letGo: { [weak self] in self?.stopFollowing() }) else { return nil }
        return (v.origin, Double(v.zoom))
    }

    /// Whether the view is flying or going along with someone.
    public var cameraMoving: Bool { camera.moving }
}

// MARK: - Easing

/// The others' marks as drawn, each easing toward where the room says it is (the Mac's LiveMarks).
final class LiveMarks {
    struct Hand {
        var at: CGPoint
        var target: CGPoint
        var alpha = 0.0
        var tag = 0.0
        var tagUntil = 0.0
        var lastMoved = 0.0
    }

    private(set) var hands: [UInt32: Hand] = [:]
    /// Each person's gaze as drawn, in canvas points.
    private(set) var lights: [UInt32: CGRect] = [:]
    private(set) var lightAlpha: [UInt32: Double] = [:]
    /// Layers others are dragging, as drawn this frame.
    private var drawn: [UUID: Node] = [:]
    private(set) var crop = 0.0
    private(set) var cropPerson: WindowsCore.LivePerson?
    private var arrivals: [UInt32: Double] = [:]
    private var last = 0.0
    private var dt = 1.0 / 60
    private var stepped = -1.0
    private var easing = false
    /// Whether something others drag is still on its way.
    private(set) var isMoving = false
    /// The design as last drawn, with what others drag; nil while nobody drags anything.
    private(set) var shown: BezzleDocument?
    /// The layers drawn with others' motion last frame, by their place in the design.
    private var movedLast: Set<Int> = []

    var isAnimating: Bool { easing || isMoving }

    func arrived(_ peer: UInt32) { arrivals[peer] = WindowsCore.now }

    private func ease(_ value: Double, _ target: Double, _ k: Double, _ moving: inout Bool) -> Double {
        if abs(target - value) < 0.004 { return target }
        moving = true
        return value + (target - value) * k
    }

    private static func mix(_ a: CGRect, _ b: CGRect, _ s: Double) -> CGRect {
        CGRect(x: a.minX + (b.minX - a.minX) * s, y: a.minY + (b.minY - a.minY) * s,
               width: a.width + (b.width - a.width) * s, height: a.height + (b.height - a.height) * s)
    }

    func step(_ room: LiveTogether, _ vp: Viewport, _ now: Double) {
        guard now != stepped else { return }
        stepped = now
        dt = last == 0 ? 1.0 / 60 : min(max(now - last, 0.001), 0.1)
        last = now
        var moving = false
        let k = { (tau: Double) -> Double in 1 - exp(-self.dt / tau) }
        let zoom = Double(vp.zoom)
        let mine = room.myPointer.map(vp.toView)

        for peer in Set(hands.keys).union(room.presence.keys) {
            let p = room.presence[peer]
            if var hand = hands[peer] {
                if let target = p?.pointer, target != hand.target {
                    if now - hand.lastMoved > 1.5 { hand.tagUntil = max(hand.tagUntil, now + 2) }
                    hand.lastMoved = now
                    hand.target = target
                }
                let d = CGPoint(x: hand.target.x - hand.at.x, y: hand.target.y - hand.at.y)
                if hypot(d.x, d.y) * zoom > 0.25 {
                    let s = k(0.075)
                    hand.at = CGPoint(x: hand.at.x + d.x * s, y: hand.at.y + d.y * s)
                    moving = true
                } else {
                    hand.at = hand.target
                }
                let wantAlpha = p?.pointer == nil ? 0 : (p?.away == true ? 0.38 : 1)
                hand.alpha = ease(hand.alpha, wantAlpha, k(0.12), &moving)
                let shownAt = vp.toView(hand.at)
                let near = mine.map { hypot(shownAt.x - $0.x, shownAt.y - $0.y) < 80 } ?? false
                let typing = p?.doing == "typing" || p?.doing == "moving"
                let wantTag: Double = p?.away == false && (now < hand.tagUntil || near || typing) ? 1 : 0
                hand.tag = ease(hand.tag, wantTag, k(wantTag > hand.tag ? 0.07 : 0.22), &moving)
                if now < hand.tagUntil { moving = true }
                if p == nil && hand.alpha < 0.01 { hands[peer] = nil } else { hands[peer] = hand }
            } else if let target = p?.pointer {
                let until = arrivals[peer].map { $0 + 3 } ?? now + 2
                hands[peer] = Hand(at: target, target: target, tagUntil: until, lastMoved: now)
                moving = true
            }
        }

        for peer in Set(lights.keys).union(room.presence.keys) {
            let want: Double = room.presence[peer] == nil ? 0 : (room.presence[peer]?.away == true ? 0.5 : 1)
            var a = lightAlpha[peer] ?? 0
            a = ease(a, want, k(0.3), &moving)
            if let target = room.presence[peer]?.view {
                if let r = lights[peer] {
                    let next = Self.mix(r, target, k(0.14))
                    let off = max(abs(next.minX - target.minX), abs(next.minY - target.minY), abs(next.width - target.width))
                    if off * zoom > 0.3 {
                        moving = true
                        lights[peer] = next
                    } else {
                        lights[peer] = target
                    }
                } else {
                    lights[peer] = target
                }
            }
            if want == 0 && a < 0.01 { lights[peer] = nil; lightAlpha[peer] = nil } else { lightAlpha[peer] = a }
        }

        if let peer = room.following, let person = room.person(peer) { cropPerson = person }
        crop = ease(crop, room.following == nil ? 0 : 1, k(room.following == nil ? 0.08 : 0.12), &moving)
        easing = moving
    }

    /// The design with what others are dragging, eased toward where they have it now; answers
    /// the layers to draw again, by their place in the design (the Mac's overlaid).
    func overlay(_ doc: BezzleDocument, _ room: LiveTogether, _ vp: Viewport) -> Set<Int> {
        guard !room.motion.isEmpty || !drawn.isEmpty else {
            isMoving = false
            shown = nil
            defer { movedLast = [] }
            return movedLast
        }
        var targets: [UUID: Node] = [:]
        for m in room.motion.values { for (id, n) in m.nodes { targets[id] = n } }
        let k = 1 - exp(-dt / 0.055)
        let zoom = Double(vp.zoom)
        var next: [UUID: Node] = [:]
        var moving = false
        var out = doc
        var places: Set<Int> = []
        func put(_ id: UUID, _ n: Node) {
            next[id] = n
            out.update(id) { node in
                let kids = node.children
                node = n
                node.children = kids
            }
            if let top = doc.path(of: id)?.top { places.insert(top) }
        }
        for (id, target) in targets {
            guard let base = doc.node(id) else { continue }
            let from = drawn[id] ?? LiveTogether.alone(base)
            if Self.close(from, target, zoom) {
                put(id, target)
            } else {
                put(id, from.blended(to: target, k))
                moving = true
            }
        }
        // A drag that went without its change, as when its maker left: back to the design as it is.
        for (id, was) in drawn where targets[id] == nil {
            guard let base = doc.node(id) else { continue }
            let to = LiveTogether.alone(base)
            guard !Self.close(was, to, zoom) else { continue }
            put(id, was.blended(to: to, k))
            moving = true
        }
        drawn = next
        isMoving = moving || !next.isEmpty
        shown = next.isEmpty ? nil : out
        defer { movedLast = places }
        return places.union(movedLast)
    }

    private static func close(_ a: Node, _ b: Node, _ zoom: Double) -> Bool {
        let tolerance = 0.2 / max(zoom, 0.01)
        return abs(a.frame.minX - b.frame.minX) < tolerance && abs(a.frame.minY - b.frame.minY) < tolerance
            && abs(a.frame.width - b.frame.width) < tolerance && abs(a.frame.height - b.frame.height) < tolerance
            && abs(a.rotation - b.rotation) < 0.05 && abs(a.opacity - b.opacity) < 0.005
    }
}

/// Moves a canvas's view: in flight to someone, then along with them (the Mac's LiveCamera).
final class LiveCamera {
    private var flight: CameraFlight?
    private var began = 0.0
    private var follow = false
    /// The view as last given: one that differs was moved by hand, and lets go.
    private var set: Viewport?
    private var last = 0.0

    var moving: Bool { flight != nil || follow }

    func fly(from current: Viewport, to target: Viewport, size: CGSize, follow: Bool) {
        self.follow = follow
        flight = CameraFlight(from: current.shot(in: size), to: target.shot(in: size))
        began = WindowsCore.now
        last = began
        set = current
    }

    func letGo() {
        follow = false
        if flight == nil { stop() }
    }

    func stop() {
        flight = nil
        set = nil
        follow = false
    }

    func step(_ current: Viewport, size: CGSize, followed: Viewport?, letGo: () -> Void) -> Viewport? {
        guard flight != nil || follow else { return nil }
        let now = WindowsCore.now
        let dt = min(now - last, 0.05)
        last = now
        if let set, !Self.near(current, set) {
            // Moved by hand: the view is this computer's own again.
            stop()
            letGo()
            return nil
        }
        if let flight {
            // Someone followed keeps moving while the view flies to them: it lands where they are now.
            var target = flight.to
            if follow, let theirs = followed { target = theirs.shot(in: size) }
            let f = (now - began) / flight.duration
            var shot = flight.shot(at: f)
            if target != flight.to {
                let k = f * f * (3 - 2 * f)
                shot.center = CGPoint(x: shot.center.x + (target.center.x - flight.to.center.x) * k, y: shot.center.y + (target.center.y - flight.to.center.y) * k)
                shot.width *= pow(target.width / flight.to.width, k)
            }
            let v = Viewport(shot, in: size)
            set = v
            if f >= 1 {
                self.flight = nil
                if !follow { stop() }
            }
            return v
        }
        guard follow, let target = followed else { stop(); return nil }
        // Along with them, a little behind, as a hand following a hand.
        let k = 1 - exp(-dt / 0.09)
        let a = current.shot(in: size), b = target.shot(in: size)
        let shot = CameraFlight.Shot(center: CGPoint(x: a.center.x + (b.center.x - a.center.x) * k, y: a.center.y + (b.center.y - a.center.y) * k),
                                     width: a.width * pow(b.width / a.width, k))
        let v = Viewport(shot, in: size)
        guard !Self.near(v, current) else {
            set = current
            return nil
        }
        set = v
        return v
    }

    private static func near(_ a: Viewport, _ b: Viewport) -> Bool {
        abs(a.zoom - b.zoom) <= 1e-6 * max(a.zoom, b.zoom) && abs(a.origin.x - b.origin.x) < 1e-3 && abs(a.origin.y - b.origin.y) < 1e-3
    }
}
