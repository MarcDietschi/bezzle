import AppKit

/// The design animated, on the canvas. The artboard shows its film at the playhead, through its
/// camera; what is picked is posed there with the hands the canvas has everywhere: dragged to move,
/// by a corner to grow, from just outside a corner to turn, from just outside the middle of a side
/// to tip it in depth. Every pose is a key at the playhead, made without asking, and the first one
/// a layer is given comes with the design for company, so one drag is a whole motion: posed at
/// the start, the layer flies home; posed later, it leaves home for there.
///
/// The camera is picked by the small camera over the artboard's corner, or its row in the
/// timeline. Picked, the artboard itself is the thing in hand, as the camera sees it: dragged to
/// look elsewhere, by a corner to come closer, turned and tipped like any layer.
@MainActor
final class MotionTool {
    let store: DocumentStore
    var redraw: () -> Void = {}
    /// The artboard whose name is at a view point.
    var titleHit: (CGPoint) -> UUID? = { _ in nil }

    init(store: DocumentStore) {
        self.store = store
    }

    func modeChanged(_ on: Bool) {
        // Whatever was in hand as the mode changed is put back: half a pose is no pose, and a
        // gesture left open would keep every later change out of the history.
        cancel()
        hot = .none
        redraw()
    }

    // MARK: The film as it lies on the canvas

    /// The film at the playhead: its artboard, pieces and camera, and where its frame is on screen.
    struct Scene {
        var board: Node
        var pieces: [FilmPiece]
        var time: Double
        var camera: FilmCamera
        /// The film's frame, in the canvas view's points.
        var rect: CGRect
        var zoom: CGFloat

        func toView(_ p: CGPoint) -> CGPoint { CGPoint(x: rect.minX + p.x * zoom, y: rect.minY + p.y * zoom) }
        func toFrame(_ v: CGPoint) -> CGPoint { CGPoint(x: (v.x - rect.minX) / zoom, y: (v.y - rect.minY) / zoom) }

        var size: CGSize { board.frame.size }

        /// The artboard's own sheet, or one lying level above it, as the camera shows it.
        func ground(height: Double = 0) -> FilmMap { FilmLens.ground(camera, size: size, height: height) }

        /// Where a layer's four corners show on screen.
        func corners(of id: UUID) -> [CGPoint]? {
            board.filmCorners(of: id, at: time, pieces: pieces)?.map(toView)
        }

        /// The artboard's own corners as the camera shows them, on screen.
        var sheet: [CGPoint] {
            let map = ground()
            let s = size
            return [CGPoint.zero, CGPoint(x: s.width, y: 0), CGPoint(x: s.width, y: s.height), CGPoint(x: 0, y: s.height)].map { toView(map($0)) }
        }
    }

    private var piecesWorkedOut: (version: Int, board: UUID, loose: Set<UUID>, fronts: [UUID: Int], pieces: [FilmPiece])?

    var scene: Scene? {
        guard let board = store.filmBoard else { return nil }
        let loose = Set(store.posedLayers)
        let pieces: [FilmPiece]
        if let had = piecesWorkedOut, had.version == store.version, had.board == board.id, had.loose == loose, had.fronts == store.fronts {
            pieces = had.pieces
        } else {
            pieces = board.filmPieces(loose: loose)
            piecesWorkedOut = (store.version, board.id, loose, store.fronts, pieces)
        }
        let t = store.filmTime
        return Scene(board: board, pieces: pieces, time: t, camera: board.camera(at: t), rect: store.viewport.toView(board.frame), zoom: store.viewport.zoom)
    }

    // MARK: What the pointer is on

    /// A place on what is picked that a drag begins from.
    enum Grip: Equatable {
        /// A corner, by its number from the top left round to the bottom left: grows it.
        case corner(Int)
        /// The middle of a side, the top first, then round: grows it one way.
        case side(Int)
        /// Just outside a corner: turns it.
        case turn(Int)
        /// Just outside the middle of a side: tips it in depth.
        case depth(Int)
    }

    private enum Hot: Equatable {
        case none
        case layer(UUID)
        case grip(Grip)
        /// A key of the picked layer's way across the artboard, by its number.
        case bead(Int)
        case cameraChip
        /// The film's frame with the camera picked: dragging looks elsewhere.
        case look
    }

    private var hot: Hot = .none
    /// What the press took hold of: the pointer goes on saying so for as long as the drag does.
    private var held: Hot = .none

    private static func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat { hypot(a.x - b.x, a.y - b.y) }

    private static func middle(_ q: [CGPoint]) -> CGPoint {
        CGPoint(x: q.map(\.x).reduce(0, +) / CGFloat(q.count), y: q.map(\.y).reduce(0, +) / CGFloat(q.count))
    }

    private static func inside(_ v: CGPoint, _ q: [CGPoint]) -> Bool {
        let path = CGMutablePath()
        path.addLines(between: q)
        path.closeSubpath()
        return path.contains(v)
    }

    /// The grip of a four-cornered outline at a view point. `sides` are left out for the camera,
    /// which grows only evenly.
    private func grip(at v: CGPoint, on q: [CGPoint], sides: Bool) -> Grip? {
        guard q.count == 4 else { return nil }
        let mids = (0..<4).map { i in CGPoint(x: (q[i].x + q[(i + 1) % 4].x) / 2, y: (q[i].y + q[(i + 1) % 4].y) / 2) }
        let lengths = (0..<4).map { Self.distance(q[$0], q[($0 + 1) % 4]) }
        // Something with no size at all has nothing to grow or turn: it is only moved.
        guard Self.hasSize(lengths) else { return nil }
        for i in 0..<4 where Self.distance(v, q[i]) <= 7 { return .corner(i) }
        if sides {
            for i in 0..<4 where Self.carriesHandle(i, lengths) && Self.distance(v, mids[i]) <= 6 { return .side(i) }
        }
        guard !Self.inside(v, q) else { return nil }
        for i in 0..<4 where Self.distance(v, q[i]) <= 22 { return .turn(i) }
        for i in 0..<4 where lengths[i] >= 30 && Self.distance(v, mids[i]) <= 20 { return .depth(i) }
        return nil
    }

    private static func hasSize(_ lengths: [CGFloat]) -> Bool { lengths.contains { $0 >= 1 } }

    /// Whether a side carries a handle in its middle: long enough for one, and far enough from
    /// the side across that the two do not lie on each other. On a line or a hairline they would,
    /// right where it is taken hold of to be moved, and pulled there it would not stir.
    private static func carriesHandle(_ i: Int, _ lengths: [CGFloat]) -> Bool {
        lengths[i] >= 30 && lengths[(i + 1) % 4] >= 16
    }

    /// The one layer whose handles show: the only one picked.
    private func handled(_ scene: Scene) -> UUID? {
        let ids = store.posedLayers
        return ids.count == 1 && !store.film.camera ? ids[0] : nil
    }

    private func chipRect(_ scene: Scene) -> CGRect {
        CGRect(x: scene.rect.maxX - 22, y: scene.rect.minY - 21, width: 22, height: 18)
    }

    /// Whether the small camera shows at all: not over an artboard seen too small to carry it.
    private func chipShows(_ scene: Scene) -> Bool { scene.rect.width >= 60 }

    /// The layers under a view point, the topmost first, each with what holds it after it.
    private func chain(at v: CGPoint, in scene: Scene) -> [Node] {
        guard scene.rect.contains(v) else { return [] }
        // Within three points of the screen, however close the view is: the film counts in what
        // the camera and a layer's own growing add, or a camera eight times closer would find a
        // layer from twenty-four points off, and the bare sheet beside it could not be pressed.
        let tolerance = 3 / scene.zoom
        return scene.board.filmChain(at: scene.toFrame(v), time: scene.time, pieces: scene.pieces, tolerance: tolerance)
    }

    /// What a click on a chain of layers picks: the one lying on the artboard itself, unless the
    /// selection is inside a group there, whose layers are then picked, as after a double click
    /// into it. `deep` picks the topmost, through every group.
    private func pick(_ chain: [Node], in scene: Scene, deep: Bool) -> UUID? {
        let ids = chain.map(\.id)
        guard !ids.isEmpty else { return nil }
        if deep { return ids[0] }
        if let picked = store.selection.first, let way = scene.board.way(to: picked) {
            for holder in way.dropLast().reversed() {
                if let i = ids.firstIndex(of: holder.id), i > 0 { return ids[i - 1] }
            }
            if ids.contains(picked) { return picked }
        }
        return ids.last
    }

    private func find(_ v: CGPoint) -> Hot {
        guard let scene, !store.film.playing else { return .none }
        if chipShows(scene), chipRect(scene).insetBy(dx: -3, dy: -3).contains(v) { return .cameraChip }
        if store.film.camera {
            if let g = grip(at: v, on: scene.sheet, sides: false) { return .grip(g) }
            return scene.rect.contains(v) ? .look : .none
        }
        if let id = handled(scene), let q = scene.corners(of: id) {
            // What shows is taken hold of first: the handles, then the beads of its way.
            let g = grip(at: v, on: q, sides: true)
            if let g {
                switch g {
                case .corner, .side: return .grip(g)
                case .turn, .depth: break
                }
            }
            // A bead the layer lies on is not taken hold of: there the layer itself is, to be posed
            // at the playhead. Else a layer resting where a key left it could never be dragged on
            // by its middle, its last key going with it instead and the playhead back to that key.
            let here = Self.middle(q)
            for (i, bead) in beads(of: id, in: scene).enumerated() where Self.distance(v, bead.at) <= 7 && Self.distance(bead.at, here) > 1 { return .bead(i) }
            // The reach for turning and tipping begins beside the layer, not on it: a line is found
            // from a little off it, and would else be all reach, with nowhere to move it by.
            if let g, !chain(at: v, in: scene).contains(where: { $0.id == id }) { return .grip(g) }
        }
        if let id = pick(chain(at: v, in: scene), in: scene, deep: false) { return .layer(id) }
        return .none
    }

    func hover(_ v: CGPoint?) {
        guard case .none = drag else { return }
        let next = v.map(find) ?? .none
        if next != hot {
            hot = next
            redraw()
        }
    }

    func cursor(at v: CGPoint) -> NSCursor {
        guard let scene else { return .arrow }
        let found = dragging ? held : find(v)
        switch found {
        case .grip(let g):
            let q = store.film.camera ? scene.sheet : handled(scene).flatMap { scene.corners(of: $0) } ?? []
            guard q.count == 4 else { return .arrow }
            let c = Self.middle(q)
            func angle(_ p: CGPoint) -> Double { Double(atan2(p.y - c.y, p.x - c.x)) * 180 / .pi }
            switch g {
            case .corner(let i): return Cursors.resize(angle(q[i]))
            case .side(let i): return Cursors.resize(angle(CGPoint(x: (q[i].x + q[(i + 1) % 4].x) / 2, y: (q[i].y + q[(i + 1) % 4].y) / 2)))
            case .turn(let i): return Cursors.rotate(angle(q[i]))
            case .depth: return Cursors.turn
            }
        case .bead: return .crosshair
        case .cameraChip: return .pointingHand
        case .look:
            if case .look = drag { return .closedHand }
            return .openHand
        case .layer, .none: return .arrow
        }
    }

    // MARK: Dragging

    private enum Drag {
        case none
        /// Pressed on a layer; a move once the pointer has gone a little way.
        case move(start: CGPoint, from: [UUID: (move: CGPoint, lift: Double)], started: Bool)
        case scale(id: UUID, center: CGPoint, start: CGPoint, from: CGPoint, side: Int?)
        /// Turning: `last` is where the pointer was a moment ago and `round` how far it has gone
        /// round since the press, added up move by move.
        case turn(id: UUID, center: CGPoint, last: CGPoint, round: Double, from: Double)
        case depth(id: UUID, side: Int, start: CGPoint, tilt: Double, swing: Double)
        case bead(id: UUID, key: Int, start: CGPoint, from: CGPoint, lift: Double)
        /// The camera looking elsewhere: the point of the artboard under the pointer stays under it.
        case look(start: CGPoint, camera: FilmCamera, started: Bool, under: UUID?)
        case zoom(center: CGPoint, start: CGPoint, from: Double)
        case roll(center: CGPoint, last: CGPoint, round: Double, from: Double)
        case tip(side: Int, start: CGPoint, tilt: Double, swing: Double)
        case marquee(start: CGPoint, now: CGPoint, base: [UUID])
    }

    private var drag: Drag = .none
    /// The tracks there were when the drag began, to tell afterwards whether it made a first key.
    private var tracksBefore: [UUID: Set<MotionProperty>] = [:]

    var dragging: Bool { if case .none = drag { return false } else { return true } }

    private func begin(_ ids: [UUID], _ scene: Scene) {
        tracksBefore = [:]
        for id in ids {
            let node = id == scene.board.id ? scene.board : scene.board.descendant(id)
            tracksBefore[id] = Set(node?.motionProperties ?? [])
        }
        store.beginGesture()
    }

    func down(at v: CGPoint, event: NSEvent) {
        // A press on a film that plays stops it; one that was only shown a moment goes on to what it pressed.
        if store.film.playing {
            let looking = store.film.pass?.to != nil
            store.pauseFilm()
            if !looking { return }
        }
        let flags = event.modifierFlags
        // Another artboard, by its name: its film comes to the desk.
        if let title = titleHit(v) {
            store.selection = [title]
            return
        }
        guard let scene else {
            // No film is on the desk, its artboard gone or hidden: a press on an artboard brings
            // that one's, and a press anywhere one that is there to be worked on.
            let p = store.viewport.toCanvas(v)
            let under = store.seenDoc.artboards.last { !$0.hidden && $0.frame.contains(p) }
            store.selection = under.map { [$0.id] } ?? []
            store.focusFilm()
            redraw()
            return
        }
        held = find(v)
        switch held {
        case .cameraChip:
            if store.film.camera { store.film.camera = false } else { store.pickCamera() }
        case .grip(let g):
            if store.film.camera {
                let center = scene.rect.center
                begin([scene.board.id], scene)
                switch g {
                case .corner, .side: drag = .zoom(center: center, start: v, from: scene.camera.zoom)
                case .turn: drag = .roll(center: center, last: v, round: 0, from: scene.camera.roll)
                case .depth(let i): drag = .tip(side: i, start: v, tilt: scene.camera.tilt, swing: scene.camera.swing)
                }
            } else if let id = handled(scene), let q = scene.corners(of: id), let node = scene.board.descendant(id) {
                let pose = node.pose(at: scene.time)
                let center = Self.middle(q)
                begin([id], scene)
                switch g {
                case .corner: drag = .scale(id: id, center: center, start: v, from: pose.scale, side: nil)
                case .side(let i): drag = .scale(id: id, center: center, start: v, from: pose.scale, side: i)
                case .turn: drag = .turn(id: id, center: center, last: v, round: 0, from: pose.turn)
                case .depth(let i): drag = .depth(id: id, side: i, start: v, tilt: pose.tilt, swing: pose.swing)
                }
            }
        case .bead(let i):
            guard let id = handled(scene), let node = scene.board.descendant(id), let track = node[track: .move], i < track.keys.count else { return }
            // The layer goes to the key taken hold of, so the bead in hand is the layer's own middle.
            store.seek(track.keys[i].t)
            let key = track.keys[i]
            begin([id], scene)
            drag = .bead(id: id, key: i, start: v, from: CGPoint(x: key.v[0], y: key.v[1]), lift: node.pose(at: key.t).lift)
        case .look:
            let under = pick(chain(at: v, in: scene), in: scene, deep: flags.contains(.command))
            drag = .look(start: v, camera: scene.camera, started: false, under: under)
        case .layer, .none:
            let chain = chain(at: v, in: scene)
            var id = pick(chain, in: scene, deep: flags.contains(.command))
            // A second click on what is picked goes one layer further in.
            if event.clickCount == 2, let picked = id, let i = chain.firstIndex(where: { $0.id == picked }), i > 0 { id = chain[i - 1].id }
            guard let id else {
                // The bare artboard, or the table: a loop pulled round layers picks them.
                let base = flags.contains(.shift) ? store.selection : []
                if !flags.contains(.shift) {
                    // On another artboard, its film comes to the desk.
                    let p = store.viewport.toCanvas(v)
                    let other = store.seenDoc.artboards.last { !$0.hidden && $0.frame.contains(p) && $0.id != scene.board.id }
                    store.selection = other.map { [$0.id] } ?? []
                }
                drag = .marquee(start: v, now: v, base: base)
                return
            }
            if flags.contains(.shift) {
                if store.selection.contains(id) { store.selection.removeAll { $0 == id } } else { store.selection.append(id) }
                return
            }
            if !store.selection.contains(id) { store.selection = [id] }
            guard let now = self.scene else { return }
            var from: [UUID: (move: CGPoint, lift: Double)] = [:]
            for picked in store.posedLayers {
                guard let node = now.board.descendant(picked) else { continue }
                let pose = node.pose(at: now.time)
                from[picked] = (pose.move, pose.lift)
            }
            drag = .move(start: v, from: from, started: false)
        }
        hot = .none
        redraw()
    }

    /// How far a drag between two view points moves something lying `height` above the artboard,
    /// in the artboard's own points: the same way on screen as the pointer went, whatever the camera.
    private func travel(from a: CGPoint, to b: CGPoint, height: Double, in scene: Scene) -> CGPoint {
        let map = scene.ground(height: height)
        if let p = map.back(scene.toFrame(a)), let q = map.back(scene.toFrame(b)) { return q - p }
        let k = scene.zoom * CGFloat(max(scene.camera.zoom, 0.01))
        return CGPoint(x: (b.x - a.x) / k, y: (b.y - a.y) / k)
    }

    /// A value held at a stop when it comes near it.
    private static func caught(_ x: Double, at stop: Double, within reach: Double) -> Double {
        abs(x - stop) <= reach ? stop : x
    }

    private static func degrees(_ p: CGPoint, about c: CGPoint) -> Double {
        Double(atan2(p.y - c.y, p.x - c.x)) * 180 / .pi
    }

    /// How far round `p` has gone about `c` since `start`, the short way: for the little the
    /// pointer goes between one move and the next.
    private static func turned(_ p: CGPoint, from start: CGPoint, about c: CGPoint) -> Double {
        var d = degrees(p, about: c) - degrees(start, about: c)
        while d > 180 { d -= 360 }
        while d < -180 { d += 360 }
        return d
    }

    /// A turn as it is kept: with Shift in steps of 15 degrees, else to the whole degree and
    /// held straight when it comes near straight, after however many rounds; free, as it is.
    private static func settled(_ degrees: Double, steps: Bool, free: Bool) -> Double {
        if steps { return (degrees / 15).rounded() * 15 }
        if free { return degrees }
        let whole = degrees.rounded(), straight = (whole / 360).rounded() * 360
        return abs(whole - straight) <= 2 ? straight : whole
    }

    func drag(to v: CGPoint, flags: NSEvent.ModifierFlags) {
        guard let scene else { return }
        let shift = flags.contains(.shift), free = flags.contains(.command)
        switch drag {
        case .none:
            break
        case .move(let start, let from, var started):
            if !started {
                guard Self.distance(v, start) >= 3 else { return }
                started = true
                begin(Array(from.keys), scene)
                drag = .move(start: start, from: from, started: true)
            }
            store.pose(.move, of: Array(from.keys)) { node in
                guard let was = from[node.id] else { return node.value(of: .move, at: scene.time) }
                var d = travel(from: start, to: v, height: was.lift, in: scene)
                // Shift keeps it to the way it has mostly gone.
                if shift { if abs(d.x) >= abs(d.y) { d.y = 0 } else { d.x = 0 } }
                var x = Double(was.move.x + d.x), y = Double(was.move.y + d.y)
                // Home again, along either line, it is held there.
                if !free {
                    let reach = 5 / Double(scene.zoom * CGFloat(max(scene.camera.zoom, 0.01)))
                    x = Self.caught(x, at: 0, within: reach)
                    y = Self.caught(y, at: 0, within: reach)
                }
                return [(x * 2).rounded() / 2, (y * 2).rounded() / 2]
            }
        case .scale(let id, let center, let start, let from, let side):
            var k: Double
            if let side {
                // Along the way from the middle out through that side.
                let q = scene.corners(of: id) ?? []
                let mid = q.count == 4 ? CGPoint(x: (q[side].x + q[(side + 1) % 4].x) / 2, y: (q[side].y + q[(side + 1) % 4].y) / 2) : start
                let d = CGPoint(x: mid.x - center.x, y: mid.y - center.y)
                let length = max(hypot(d.x, d.y), 0.001)
                let unit = CGPoint(x: d.x / length, y: d.y / length)
                let a = (start.x - center.x) * unit.x + (start.y - center.y) * unit.y
                let b = (v.x - center.x) * unit.x + (v.y - center.y) * unit.y
                k = Double(max(b, 1) / max(a, 1))
            } else {
                k = Double(Self.distance(v, center) / max(Self.distance(start, center), 1))
            }
            var x = Double(from.x), y = Double(from.y)
            if side == nil || side == 1 || side == 3 { x *= k }
            if side == nil || side == 0 || side == 2 { y *= k }
            if !free {
                x = Self.caught(x, at: 1, within: 0.03)
                y = Self.caught(y, at: 1, within: 0.03)
            }
            store.pose(.scale, of: [id]) { _ in [(x * 100).rounded() / 100, (y * 100).rounded() / 100] }
        case .turn(let id, let center, let last, var round, let from):
            // Round with the pointer, the way it goes: what it turns between one move and the next
            // is added up, so a turn past half a round is that turn, and not the short way back.
            // In a film the two are not the same motion.
            round += Self.turned(v, from: last, about: center)
            drag = .turn(id: id, center: center, last: v, round: round, from: from)
            let degrees = Self.settled(from + round, steps: shift, free: free)
            store.pose(.turn, of: [id]) { _ in [degrees] }
        case .depth(let id, let side, let start, let tilt, let swing):
            let (property, value) = Self.tipped(side: side, from: start, to: v, tilt: tilt, swing: swing, steps: shift, free: free)
            store.pose(property, of: [id]) { _ in [value] }
        case .bead(let id, let key, let start, let from, let lift):
            var d = travel(from: start, to: v, height: lift, in: scene)
            if shift { if abs(d.x) >= abs(d.y) { d.y = 0 } else { d.x = 0 } }
            var x = Double(from.x + d.x), y = Double(from.y + d.y)
            if !free {
                let reach = 5 / Double(scene.zoom * CGFloat(max(scene.camera.zoom, 0.01)))
                x = Self.caught(x, at: 0, within: reach)
                y = Self.caught(y, at: 0, within: reach)
            }
            store.edit(MotionProperty.move.action) { doc in
                doc.update(id) { n in
                    guard var track = n[track: .move], key < track.keys.count else { return }
                    track.keys[key].v = [(x * 2).rounded() / 2, (y * 2).rounded() / 2]
                    track.keys[key].given = nil
                    n[track: .move] = track
                }
            }
        case .look(let start, let camera, var started, let under):
            if !started {
                guard Self.distance(v, start) >= 3 else { return }
                started = true
                begin([scene.board.id], scene)
                drag = .look(start: start, camera: camera, started: true, under: under)
            }
            // The point of the artboard taken hold of stays under the pointer.
            let size = scene.size
            guard let held = FilmLens.ground(camera, size: size).back(scene.toFrame(start)) else { return }
            var c = camera
            for _ in 0..<6 {
                guard let now = FilmLens.ground(c, size: size).back(scene.toFrame(v)) else { break }
                c.x += Double(held.x - now.x)
                c.y += Double(held.y - now.y)
            }
            var x = c.x, y = c.y
            if shift { if abs(x - camera.x) >= abs(y - camera.y) { y = camera.y } else { x = camera.x } }
            if !free {
                let reach = 5 / Double(scene.zoom * CGFloat(max(camera.zoom, 0.01)))
                x = Self.caught(x, at: 0, within: reach)
                y = Self.caught(y, at: 0, within: reach)
            }
            store.poseCamera(.cameraMove, [x.rounded(), y.rounded()])
        case .zoom(let center, let start, let from):
            var zoom = from * Double(Self.distance(v, center) / max(Self.distance(start, center), 1))
            if !free { zoom = Self.caught(zoom, at: 1, within: 0.03) }
            store.poseCamera(.cameraZoom, [(zoom * 100).rounded() / 100])
        case .roll(let center, let last, var round, let from):
            round += Self.turned(v, from: last, about: center)
            drag = .roll(center: center, last: v, round: round, from: from)
            store.poseCamera(.cameraRoll, [Self.settled(from + round, steps: shift, free: free)])
        case .tip(let side, let start, let tilt, let swing):
            let (property, value) = Self.tipped(side: side, from: start, to: v, tilt: tilt, swing: swing, steps: shift, free: free)
            store.poseCamera(property == .tilt ? .cameraTilt : .cameraSwing, [value])
        case .marquee(let start, _, let base):
            drag = .marquee(start: start, now: v, base: base)
            let loop = Geometry.rect(from: start, to: v)
            var ids = base
            for layer in scene.board.children where !layer.hidden && !layer.locked && !ids.contains(layer.id) {
                guard let q = scene.corners(of: layer.id) else { continue }
                let xs = q.map(\.x), ys = q.map(\.y)
                let box = CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
                if box.intersects(loop) { ids.append(layer.id) }
            }
            if ids != store.selection { store.selection = ids }
        }
        redraw()
    }

    /// A side pulled from just outside its middle: the top or bottom tips it, a side swings it,
    /// that edge going away as it is pushed in toward the middle. Shift goes in steps of 15°.
    private static func tipped(side: Int, from start: CGPoint, to v: CGPoint, tilt: Double, swing: Double, steps: Bool, free: Bool) -> (MotionProperty, Double) {
        let rate = 0.6
        // The top or bottom pushed down tips the top away; a side pushed left swings the right away.
        let property: MotionProperty = side % 2 == 0 ? .tilt : .swing
        var value = side % 2 == 0 ? tilt + Double(v.y - start.y) * rate : swing - Double(v.x - start.x) * rate
        if steps { value = (value / 15).rounded() * 15 } else if !free { value = caught(value.rounded(), at: 0, within: 3) }
        return (property, value)
    }

    func up(at v: CGPoint, flags: NSEvent.ModifierFlags) {
        let was = drag
        drag = .none
        defer {
            hot = find(v)
            redraw()
        }
        switch was {
        case .none, .marquee:
            return
        case .move(_, _, let started):
            guard started else { return }
            finish(MotionProperty.move.action)
        case .look(_, _, let started, let under):
            guard started else {
                // A click on a layer while the camera is in hand picks the layer instead.
                if let under { store.selection = [under] }
                return
            }
            finish(MotionProperty.cameraMove.action)
        case .scale: finish(MotionProperty.scale.action)
        case .turn: finish(MotionProperty.turn.action)
        case .depth(_, let side, _, _, _): finish((side % 2 == 0 ? MotionProperty.tilt : .swing).action)
        case .bead: finish(MotionProperty.move.action)
        case .zoom: finish(MotionProperty.cameraZoom.action)
        case .roll: finish(MotionProperty.cameraRoll.action)
        case .tip(let side, _, _, _): finish((side % 2 == 0 ? MotionProperty.cameraTilt : .cameraSwing).action)
        }
    }

    /// Ends a drag as one step, and where it gave something its first key, shows the motion that
    /// made: once through, and the playhead back where it was.
    private func finish(_ action: LocalizedStringResource) {
        let before = tracksBefore
        tracksBefore = [:]
        // Let go where the design has it, something that had no keys is given none: keys that all
        // say "as designed" are no motion, only a row in the timeline and a step to undo.
        if store.inGesture {
            store.edit(action) { doc in
                for (id, had) in before {
                    doc.update(id) { n in
                        for p in n.motionProperties where !had.contains(p) {
                            guard let track = n[track: p], track.keys.allSatisfy({ MotionTiming.alike($0.v, p.rest) }) else { continue }
                            n[track: p] = nil
                        }
                    }
                }
            }
        }
        store.endGesture(action)
        guard let board = store.filmBoard else { return }
        let t = store.filmTime
        var span: (from: Double, to: Double)?
        for (id, had) in before {
            guard let node = id == board.id ? board : board.descendant(id) else { continue }
            for p in node.motionProperties where !had.contains(p) {
                guard let track = node[track: p], let a = track.start, let b = track.end, b > a else { continue }
                span = (min(span?.from ?? a, a), max(span?.to ?? b, b))
            }
        }
        if let span { store.showFilm(from: span.from, to: span.to, back: t) }
    }

    @discardableResult
    func cancel() -> Bool {
        guard dragging || !fingers.isEmpty else { return false }
        if store.inGesture { store.cancelGesture() }
        drag = .none
        // What is left of two fingers put back does nothing more.
        spent.formUnion(fingers)
        fingers = []
        tracksBefore = [:]
        redraw()
        return true
    }

    // MARK: Two fingers on the camera

    /// The two ways two fingers move the camera.
    private enum Fingers { case pinch, twist }
    /// Those going on now, as the camera's. Both can at once, and are one step together.
    private var fingers: Set<Fingers> = []
    /// Those put back while they went on, whose every further move is swallowed until they end.
    private var spent: Set<Fingers> = []

    /// Whether two fingers put down at a view point are the camera's: with the camera picked,
    /// nothing else in hand, and the pointer on its film.
    private func cameraIsUnder(_ v: CGPoint) -> Bool {
        guard store.film.camera, !store.film.playing, !dragging, let scene else { return false }
        return scene.rect.contains(v)
    }

    /// A pinch: the camera comes closer or draws back. False where the pinch is the view's.
    func magnify(_ event: NSEvent, at v: CGPoint) -> Bool {
        gesture(.pinch, event, at: v, MotionProperty.cameraZoom.action) { scene in
            store.poseCamera(.cameraZoom, [scene.camera.zoom * (1 + Double(event.magnification))])
        }
    }

    /// Two fingers turned: the camera rolls with them. False where they are not the camera's.
    func rotate(_ event: NSEvent, at v: CGPoint) -> Bool {
        gesture(.twist, event, at: v, MotionProperty.cameraRoll.action) { scene in
            store.poseCamera(.cameraRoll, [scene.camera.roll - Double(event.rotation)])
        }
    }

    /// Two fingers are the camera's or the view's as they are put down, and stay so until they
    /// are lifted: from first to last they pose the camera as one step. Told of them only after
    /// they began, as when a motion was still being shown then, the camera leaves them alone.
    private func gesture(_ kind: Fingers, _ event: NSEvent, at v: CGPoint, _ action: LocalizedStringResource, _ change: (Scene) -> Void) -> Bool {
        let phase = event.phase
        let begins = phase.contains(.began), ends = phase.contains(.ended) || phase.contains(.cancelled)
        if spent.contains(kind) {
            if begins || ends || phase.isEmpty { spent.remove(kind) }
            if !begins && !phase.isEmpty { return true }
        }
        if phase.isEmpty {
            // From something that does not say where its gestures begin and end, each is a step.
            guard fingers.isEmpty, cameraIsUnder(v), let scene else { return false }
            begin([scene.board.id], scene)
            change(scene)
            finish(action)
            return true
        }
        if begins, !fingers.contains(kind) {
            guard cameraIsUnder(v), let scene else { return false }
            if fingers.isEmpty { begin([scene.board.id], scene) }
            fingers.insert(kind)
        }
        guard fingers.contains(kind) else { return false }
        if let scene { change(scene) }
        if ends {
            fingers.remove(kind)
            if fingers.isEmpty { finish(action) }
        }
        return true
    }

    // MARK: Keys

    /// A key while the design is animated. Delete takes keys away, never layers; Return plays
    /// from the start; the arrows nudge what is picked, or with nothing picked step through time.
    func key(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .numericPad, .function])
        let shift = flags.contains(.shift)
        switch event.keyCode {
        case 49:
            return false
        case 36, 76:
            store.playFilm(fromStart: true)
        case 51, 117:
            store.removeFilmKeys()
        case 53:
            if cancel() { return true }
            if store.film.playing { store.pauseFilm() } else if !store.film.keys.isEmpty { store.film.keys = [] }
            else if store.film.camera { store.film.camera = false } else { store.selection = [] }
        case 115:
            store.seek(0)
        case 119:
            store.seek(store.filmBoard?.filmLength ?? 0)
        case 123, 124, 125, 126:
            guard flags.subtracting([.shift, .option]).isEmpty else { return false }
            let dx: Double = event.keyCode == 123 ? -1 : event.keyCode == 124 ? 1 : 0
            let dy: Double = event.keyCode == 126 ? -1 : event.keyCode == 125 ? 1 : 0
            if flags.contains(.option), dx != 0 {
                store.stepToKey(forward: dx > 0)
                return true
            }
            let step: Double = shift ? 10 : 1
            let ids = store.posedLayers
            if store.film.camera, let scene {
                store.poseCamera(.cameraMove, [scene.camera.x + dx * step, scene.camera.y + dy * step])
            } else if !ids.isEmpty, let scene {
                store.pose(.move, of: ids) { node in
                    let was = node.value(of: .move, at: scene.time)
                    return [was[0] + dx * step, was[1] + dy * step]
                }
            } else if dx != 0 {
                stepFrames(Int(dx) * (shift ? 10 : 1))
            }
        default:
            guard flags.subtracting(.shift).isEmpty, var chars = event.charactersIgnoringModifiers?.lowercased() else { return false }
            // With Shift the comma and the full stop type something else, and what, each keyboard
            // decides for itself: it is the key that counts, as it is without Shift.
            if shift, let plain = event.characters(byApplyingModifiers: []), plain == "," || plain == "." { chars = plain }
            switch chars {
            case ",": stepFrames(shift ? -10 : -1)
            case ".": stepFrames(shift ? 10 : 1)
            case "k": store.holdHere()
            default:
                // The drawing tools' letters do nothing here; anything else goes on as it would.
                return Tool.forKey(chars) != nil
            }
        }
        return true
    }

    /// Steps the playhead by frames of a sixtieth of a second, onto the frames themselves: a
    /// moment is kept to the thousandth, so a sixtieth added to it each time would drift, and
    /// sixty steps come out longer than a second.
    private func stepFrames(_ count: Int) {
        let frames = store.filmTime * 60
        let from = count > 0 ? (frames + 0.05).rounded(.down) : (frames - 0.05).rounded(.up)
        store.seek((from + Double(count)) / 60)
    }

    // MARK: Right click

    func menuEntries(at v: CGPoint) -> [MenuEntry]? {
        guard let scene, !store.film.playing else { return nil }
        if !store.film.camera, let id = pick(chain(at: v, in: scene), in: scene, deep: false), !store.selection.contains(id) {
            store.selection = [id]
        }
        let some = store.film.camera || !store.posedLayers.isEmpty
        var entries: [MenuEntry] = []
        if some {
            entries.append(.item("Hold Here", shortcut: "K") { [store] in store.holdHere() })
            entries.append(.item("Remove Key", shortcut: "⌫", enabled: store.hasKeysToRemove) { [store] in store.removeFilmKeys() })
            if store.hasKeysToRemove {
                entries.append(.separator)
                let shared = store.sharedEase
                for kind in MotionEase.Kind.allCases {
                    let ease = kind == .spring ? MotionEase.spring() : MotionEase(kind: kind)
                    entries.append(.item(.verbatim(ease.title), checked: shared?.kind == kind) { [store] in store.setEase(ease) })
                }
            }
            entries.append(.separator)
        }
        entries.append(.item(some ? "Remove Motion" : "Remove All Motion", enabled: some ? true : scene.board.hasFilm) { [store] in store.clearFilmMotion() })
        entries.append(.separator)
        entries.append(.item(store.film.playing ? "Pause" : "Play", shortcut: "␣") { [store] in store.toggleFilm() })
        return entries
    }

    // MARK: Drawing

    /// A key of the picked layer's way across the artboard: where its middle is then, on screen.
    private struct Bead {
        var at: CGPoint
        var time: Double
        /// At home: where the design has the layer.
        var home: Bool
    }

    /// Where a layer's middle shows at a moment.
    private func middle(of id: UUID, at t: Double, in scene: Scene) -> CGPoint? {
        guard let q = scene.board.filmCorners(of: id, at: t, pieces: scene.pieces) else { return nil }
        return scene.toView(Self.middle(q))
    }

    private func beads(of id: UUID, in scene: Scene) -> [Bead] {
        guard let node = scene.board.descendant(id), let track = node[track: .move], track.keys.count >= 2 else { return [] }
        return track.keys.compactMap { key in
            middle(of: id, at: key.t, in: scene).map { Bead(at: $0, time: key.t, home: MotionTiming.alike(key.v, MotionProperty.move.rest)) }
        }
    }

    private func outline(_ points: [CGPoint]) -> CGPath {
        let path = CGMutablePath()
        path.addLines(between: points)
        path.closeSubpath()
        return path
    }

    private func drawHandle(_ p: CGPoint, in ctx: CGContext, scale: CGFloat, round: Bool = false) {
        let c = CGPoint(x: (p.x * scale).rounded() / scale, y: (p.y * scale).rounded() / scale)
        let rect = CGRect(center: c, size: CGSize(width: 8, height: 8))
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -0.5 * scale), blur: 1.5 * scale, color: NSColor.black.withAlphaComponent(0.18).cgColor)
        ctx.setFillColor(.white)
        if round { ctx.fillEllipse(in: rect) } else { ctx.fill(rect) }
        ctx.restoreGState()
        ctx.setStrokeColor(CanvasInk.pencil.cgColor)
        ctx.setLineWidth(1)
        if round { ctx.strokeEllipse(in: rect.insetBy(dx: 0.5, dy: 0.5)) } else { ctx.stroke(rect.insetBy(dx: 0.5, dy: 0.5)) }
    }

    func draw(_ ctx: CGContext, scale: CGFloat, in bounds: CGRect) {
        guard let scene else { return }
        drawChip(ctx, scene)
        // While the film plays, nothing lies over it.
        guard !store.film.playing else { return }
        ctx.saveGState()
        defer { ctx.restoreGState() }
        if store.film.camera {
            drawCamera(ctx, scene, scale: scale)
            return
        }
        let picked = store.posedLayers
        // Where the design has what is picked, while it is somewhere else: its home, dashed.
        for id in picked {
            guard let node = scene.board.descendant(id), !node.pose(at: scene.time).isRest,
                  let home = homeCorners(of: id, in: scene) else { continue }
            ctx.addPath(outline(home))
            ctx.setStrokeColor(CanvasInk.pencil.withAlphaComponent(0.45).cgColor)
            ctx.setLineWidth(1)
            ctx.setLineDash(phase: 0, lengths: [3, 3])
            ctx.strokePath()
            ctx.setLineDash(phase: 0, lengths: [])
        }
        if let id = handled(scene) { drawWay(of: id, ctx, scene) }
        if case .layer(let id) = hot, !picked.contains(id), let q = scene.corners(of: id) {
            ctx.addPath(outline(q))
            ctx.setStrokeColor(CanvasInk.pencil.cgColor)
            ctx.setLineWidth(1.5)
            ctx.strokePath()
        }
        ctx.setStrokeColor(CanvasInk.pencil.cgColor)
        ctx.setLineWidth(1)
        for id in picked {
            guard let q = scene.corners(of: id) else { continue }
            ctx.addPath(outline(q))
            ctx.strokePath()
        }
        if let id = handled(scene), let q = scene.corners(of: id) {
            let moving: Bool = { if case .move(_, _, true) = drag { return true } else { return false } }()
            if !moving {
                let lengths = (0..<4).map { Self.distance(q[$0], q[($0 + 1) % 4]) }
                for i in 0..<4 where Self.carriesHandle(i, lengths) {
                    drawHandle(CGPoint(x: (q[i].x + q[(i + 1) % 4].x) / 2, y: (q[i].y + q[(i + 1) % 4].y) / 2), in: ctx, scale: scale)
                }
                if Self.hasSize(lengths) { for p in q { drawHandle(p, in: ctx, scale: scale) } }
            }
        }
        if case .marquee(let start, let now, _) = drag {
            let rect = Geometry.rect(from: start, to: now)
            ctx.setFillColor(CanvasInk.pencil.withAlphaComponent(0.08).cgColor)
            ctx.fill(rect)
            ctx.setStrokeColor(CanvasInk.pencil.withAlphaComponent(0.8).cgColor)
            ctx.setLineWidth(1)
            ctx.stroke(rect.insetBy(dx: 0.5, dy: 0.5))
        }
    }

    /// Where a layer's corners would show at home, as designed, through the camera as it is now.
    private func homeCorners(of id: UUID, in scene: Scene) -> [CGPoint]? {
        var board = scene.board
        func strip(_ n: inout Node) {
            if n.id == id {
                for p in MotionProperty.layer { n[track: p] = nil }
                return
            }
            for i in n.children.indices { strip(&n.children[i]) }
        }
        strip(&board)
        // The camera where it is now, whatever its keys say of other moments.
        let pieces = board.filmPieces(loose: [id])
        guard let piece = pieces.first(where: { $0.layers == [id] }), let layer = board.descendant(id),
              let way = board.way(to: id) else { return nil }
        let origin = way.dropLast().reduce(CGPoint.zero) { CGPoint(x: $0.x + $1.frame.minX, y: $0.y + $1.frame.minY) }
        let map = board.placement(of: piece, at: scene.time, camera: scene.camera).map
        let turn = BezzleDocument.turnedBox(of: layer)
        let box = layer.isGroup ? turn.frame.offsetBy(dx: origin.x, dy: origin.y) : layer.frame.offsetBy(dx: origin.x, dy: origin.y)
        return Geometry.corners(of: box, rotation: turn.rotation).map { scene.toView(map($0)) }
    }

    /// The picked layer's way across the artboard: a fine line through where its middle goes,
    /// ticked at even moments, so that where the ticks crowd it goes slowly; and a bead at each
    /// key, hollow where the key is the design's own place.
    private func drawWay(of id: UUID, _ ctx: CGContext, _ scene: Scene) {
        guard let node = scene.board.descendant(id), let track = node[track: .move], track.keys.count >= 2,
              let a = track.start, let b = track.end, b > a else { return }
        let steps = max(2, min(240, Int(((b - a) * 60).rounded())))
        var points: [CGPoint] = []
        for k in 0...steps {
            if let p = middle(of: id, at: a + (b - a) * Double(k) / Double(steps), in: scene) { points.append(p) }
        }
        guard points.count >= 2 else { return }
        let line = CGMutablePath()
        line.addLines(between: points)
        ctx.addPath(line)
        ctx.setStrokeColor(CanvasInk.pencil.withAlphaComponent(0.55).cgColor)
        ctx.setLineWidth(1)
        ctx.strokePath()
        // A tick each twentieth of a second.
        ctx.setFillColor(CanvasInk.pencil.cgColor)
        let every = max(1, Int((Double(steps) / ((b - a) * 20)).rounded()))
        for (k, p) in points.enumerated() where k % every == 0 && k != 0 && k != points.count - 1 {
            ctx.fillEllipse(in: CGRect(center: p, size: CGSize(width: 2.5, height: 2.5)))
        }
        for (i, bead) in beads(of: id, in: scene).enumerated() {
            let onIt = MotionTiming.same(bead.time, scene.time)
            let hovered = hot == .bead(i)
            let size: CGFloat = hovered || onIt ? 9 : 7
            let rect = CGRect(center: bead.at, size: CGSize(width: size, height: size))
            ctx.setFillColor(bead.home ? NSColor.white.cgColor : CanvasInk.pencil.cgColor)
            ctx.fillEllipse(in: rect)
            ctx.setStrokeColor(bead.home ? CanvasInk.pencil.cgColor : NSColor.white.cgColor)
            ctx.setLineWidth(bead.home ? 1.5 : 1)
            ctx.strokeEllipse(in: bead.home ? rect.insetBy(dx: 0.75, dy: 0.75) : rect)
        }
    }

    /// The camera in hand: the artboard as it sees it, outlined, with a corner's handle at each corner.
    private func drawCamera(_ ctx: CGContext, _ scene: Scene, scale: CGFloat) {
        let q = scene.sheet
        // The film's frame, which stays where it is whatever the camera does.
        ctx.setStrokeColor(CanvasInk.pencil.withAlphaComponent(0.45).cgColor)
        ctx.setLineWidth(1)
        ctx.setLineDash(phase: 0, lengths: [3, 3])
        ctx.stroke(scene.rect.insetBy(dx: -0.5, dy: -0.5))
        ctx.setLineDash(phase: 0, lengths: [])
        ctx.addPath(outline(q))
        ctx.setStrokeColor(CanvasInk.pencil.cgColor)
        ctx.strokePath()
        // Where it looks: a small cross at the middle of the frame.
        let c = scene.rect.center
        ctx.move(to: CGPoint(x: c.x - 5, y: c.y)); ctx.addLine(to: CGPoint(x: c.x + 5, y: c.y))
        ctx.move(to: CGPoint(x: c.x, y: c.y - 5)); ctx.addLine(to: CGPoint(x: c.x, y: c.y + 5))
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.9).cgColor)
        ctx.setLineWidth(3)
        ctx.strokePath()
        ctx.move(to: CGPoint(x: c.x - 5, y: c.y)); ctx.addLine(to: CGPoint(x: c.x + 5, y: c.y))
        ctx.move(to: CGPoint(x: c.x, y: c.y - 5)); ctx.addLine(to: CGPoint(x: c.x, y: c.y + 5))
        ctx.setStrokeColor(CanvasInk.pencil.cgColor)
        ctx.setLineWidth(1)
        ctx.strokePath()
        for p in q { drawHandle(p, in: ctx, scale: scale) }
    }

    /// The small camera over the artboard's top right corner: a click takes the camera in hand.
    private func drawChip(_ ctx: CGContext, _ scene: Scene) {
        guard chipShows(scene) else { return }
        let r = chipRect(scene)
        let on = store.film.camera
        let color = on ? CanvasInk.labelSelected : hot == .cameraChip ? CanvasInk.labelSelected.withAlphaComponent(0.8) : CanvasInk.label
        ctx.saveGState()
        let body = CGRect(x: r.maxX - 17, y: r.minY + 5, width: 11, height: 8.5)
        let lens = CGMutablePath()
        lens.move(to: CGPoint(x: body.maxX + 1.5, y: body.midY))
        lens.addLine(to: CGPoint(x: body.maxX + 5.5, y: body.minY + 0.8))
        lens.addLine(to: CGPoint(x: body.maxX + 5.5, y: body.maxY - 0.8))
        lens.closeSubpath()
        ctx.setStrokeColor(color.cgColor)
        ctx.setFillColor(color.cgColor)
        ctx.setLineWidth(1.3)
        ctx.setLineJoin(.round)
        let box = CGPath(roundedRect: body, cornerWidth: 2, cornerHeight: 2, transform: nil)
        ctx.addPath(box)
        ctx.addPath(lens)
        if on { ctx.drawPath(using: .fillStroke) } else { ctx.strokePath() }
        // A bead beside it once the camera has keys.
        if scene.board.hasCamera {
            ctx.fillEllipse(in: CGRect(x: body.minX - 8, y: body.midY - 2, width: 4, height: 4))
        }
        ctx.restoreGState()
    }
}
