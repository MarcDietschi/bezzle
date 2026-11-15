import AppKit

/// The design animated, on the canvas. The artboard shows its film at the playhead, through its
/// camera; what is picked is posed there with the hands the canvas has everywhere: dragged to move,
/// by a corner to grow, from just outside a corner to turn, from just outside the middle of a side
/// to tip it in depth. Every pose is a key at the playhead, made without asking, and the first one
/// a layer is given comes with the design for company, so one drag is a whole motion: posed at
/// the start, the layer flies home; posed later, it leaves home for there. Several picked that
/// lie together are one body, with one set of handles round them that pose it as one.
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

    /// A shape's points moved at the playhead, with the pen's hands: each move poses its Shape
    /// there (`FilmPoints`). A double click on a shape, or Edit Points in the panel, takes them in hand.
    private(set) lazy var points: PathTool = {
        let tool = PathTool(store: store, host: FilmPoints(store: store) { [weak self] in
            guard let scene = self?.scene else { return nil }
            return (scene.board, scene.pieces)
        })
        tool.redraw = { [weak self] in self?.redraw() }
        return tool
    }()

    func modeChanged(_ on: Bool) {
        // Whatever was in hand as the mode changed is put back: half a pose is no pose, and a
        // gesture left open would keep every later change out of the history.
        cancel()
        // Points in hand are the film's: the design's own are taken in hand there anew.
        store.editingPath = nil
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
        /// The dot inside a corner of the picked rectangle, by the corner's number: rounds its corners.
        case round(Int)
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

    /// Several layers picked that lie together, as one body at the playhead (`FilmBody`), and
    /// the box round it in the plane of its lead's face, where its one set of handles shows, in
    /// the film frame's points: top left round to bottom left.
    struct Body {
        var body: FilmBody
        var outline: [CGPoint]
        var ids: [UUID] { body.ids }
    }

    /// The body is worked out once for each design, selection and moment, and kept while the
    /// view moves: it is asked of at every frame and every move of the pointer.
    private var bodyWorkedOut: (version: Int, fronts: [UUID: Int], board: UUID, ids: [UUID], time: Double, body: Body?)?

    /// What is picked as one body, when it is several layers lying together (on the artboard,
    /// or in one group on it): the Pose card's Tilt and Swing pose those as one, and so do the
    /// handles round them. Nil for one layer, or for layers lying apart.
    func body(_ scene: Scene) -> Body? {
        let ids = store.posedLayers
        guard ids.count > 1, !store.film.camera else { return nil }
        if let had = bodyWorkedOut, had.version == store.version, had.fronts == store.fronts, had.board == scene.board.id, had.ids == ids, had.time == scene.time {
            return had.body
        }
        var found: Body?
        if let body = store.seenDoc.filmBody(of: ids, at: scene.time), let map = leadMap(body, scene) {
            let outline = body.outline.map { map($0) }
            if outline.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) { found = Body(body: body, outline: outline) }
        }
        bodyWorkedOut = (store.version, store.fronts, scene.board.id, ids, scene.time, found)
        return found
    }

    /// Where a body's lead's own upright points show in the film's frame. Through its corners
    /// as the film shows them, which count in how it stands off a group drawn as one card; a
    /// group, whose corners are those of what it holds, or a shape whose outline moves, through
    /// the film's map of the layer itself.
    private func leadMap(_ body: FilmBody, _ scene: Scene) -> FilmMap? {
        let lead = body.layers[body.lead]
        let w = Double(lead.frame.width), h = Double(lead.frame.height)
        if !lead.isGroup, !lead.reshapes, w > 0, h > 0, let q = scene.board.filmCorners(of: lead.id, at: scene.time, pieces: scene.pieces),
           let square = FilmMap.square(to: q) {
            return square.after(FilmMap(a: 1 / w, e: 1 / h))
        }
        return scene.board.filmPointMap(of: lead.id, at: scene.time, pieces: scene.pieces)
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
            if let dots = cornerDots(scene), let i = dots.at.firstIndex(where: { Self.distance(v, $0) <= 6 }) { return .round(i) }
            // A bead the layer lies on is not taken hold of: there the layer itself is, to be posed
            // at the playhead. Else a layer resting where a key left it could never be dragged on
            // by its middle, its last key going with it instead and the playhead back to that key.
            let here = Self.middle(q)
            for (i, bead) in beads(of: id, in: scene).enumerated() where Self.distance(v, bead.at) <= 7 && Self.distance(bead.at, here) > 1 { return .bead(i) }
            // The reach for turning and tipping begins beside the layer, not on it: a line is found
            // from a little off it, and would else be all reach, with nowhere to move it by.
            if let g, !chain(at: v, in: scene).contains(where: { $0.id == id }) { return .grip(g) }
        }
        // Several as one body: its handles first, and beside it the reach for turning and tipping
        // it, where none of its layers is.
        if let held = body(scene), let g = grip(at: v, on: held.outline.map(scene.toView), sides: true) {
            switch g {
            case .corner, .side: return .grip(g)
            case .turn, .depth: if !chain(at: v, in: scene).contains(where: { held.ids.contains($0.id) }) { return .grip(g) }
            }
        }
        if let id = pick(chain(at: v, in: scene), in: scene, deep: false) { return .layer(id) }
        return .none
    }

    func hover(_ v: CGPoint?) {
        if store.editingPath != nil { points.hover(v, flags: []) }
        guard case .none = drag else { return }
        let next = v.map(find) ?? .none
        if next != hot {
            hot = next
            redraw()
        }
    }

    func cursor(at v: CGPoint) -> NSCursor {
        if store.editingPath != nil, let cursor = points.cursor { return cursor }
        guard let scene else { return .arrow }
        let found = dragging ? held : find(v)
        switch found {
        case .grip(let g):
            let q = store.film.camera ? scene.sheet
                : handled(scene).flatMap { scene.corners(of: $0) } ?? body(scene)?.outline.map(scene.toView) ?? []
            guard q.count == 4 else { return .arrow }
            let c = Self.middle(q)
            func angle(_ p: CGPoint) -> Double { Double(atan2(p.y - c.y, p.x - c.x)) * 180 / .pi }
            switch g {
            case .corner(let i): return Cursors.resize(angle(q[i]))
            case .side(let i): return Cursors.resize(angle(CGPoint(x: (q[i].x + q[(i + 1) % 4].x) / 2, y: (q[i].y + q[(i + 1) % 4].y) / 2)))
            case .turn(let i): return Cursors.rotate(angle(q[i]))
            case .depth: return Cursors.turn
            }
        case .bead, .round: return .crosshair
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
        /// Several layers as one body (`FilmBody`), by the handles round it: grown about its
        /// middle, turned in the plane of its lead's face, or tipped and swung in depth. What is
        /// kept is its lead's: its scale, turn, tilt and swing at the press.
        case bodyScale(ids: [UUID], center: CGPoint, start: CGPoint, from: CGPoint, side: Int?)
        case bodyTurn(ids: [UUID], center: CGPoint, last: CGPoint, round: Double, from: Double)
        case bodyDepth(ids: [UUID], side: Int, start: CGPoint, tilt: Double, swing: Double)
        case bead(id: UUID, key: Int, start: CGPoint, from: CGPoint, lift: Double)
        /// A rectangle's corners rounded by the dot inside one: `radii` as they were at the press.
        case round(id: UUID, corner: Int, radii: [CGFloat])
        /// The camera looking elsewhere: the point of the artboard under the pointer stays under it.
        case look(start: CGPoint, camera: FilmCamera, started: Bool, under: UUID?)
        case zoom(center: CGPoint, start: CGPoint, from: Double)
        case roll(center: CGPoint, last: CGPoint, round: Double, from: Double)
        case tip(side: Int, start: CGPoint, tilt: Double, swing: Double)
        case marquee(start: CGPoint, now: CGPoint, base: [UUID])
    }

    private var drag: Drag = .none
    /// A move with Control held lifts what is dragged instead (`DepthPushing`), in view points.
    private var pushing = DepthPushing()
    /// The tracks there were when the drag began, to tell afterwards whether it made a first key.
    private var tracksBefore: [UUID: Set<MotionProperty>] = [:]
    /// The plane each layer in hand is moved along, as the film shows it (`Node.filmMovePlane`):
    /// worked out as a move or a bead's drag begins, so the pointer is cast onto it at each step.
    private var planes: [UUID: FilmMap] = [:]

    var dragging: Bool {
        if points.dragging { return true }
        if case .none = drag { return false } else { return true }
    }

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
        // A shape's points in hand: pressed on, they move; off them, a loop round some, or out of
        // editing to whatever was pressed. A double click off them puts them down.
        if store.editingPath != nil {
            if points.editDown(at: v, event: event) {
                redraw()
                return
            }
            let other = pick(chain(at: v, in: scene), in: scene, deep: flags.contains(.command))
            if other == nil || other == store.editingPath {
                if event.clickCount >= 2 { store.editingPath = nil } else {
                    points.startMarquee(at: v, adding: flags.contains(.shift), offPath: other == nil)
                }
                redraw()
                return
            }
            store.editingPath = nil
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
            } else if let held = body(scene) {
                // Several as one body: what its lead is at the press, which the body follows.
                let ids = held.ids, pose = held.body.poses[held.body.lead]
                let center = Self.middle(held.outline.map(scene.toView))
                begin(ids, scene)
                switch g {
                case .corner: drag = .bodyScale(ids: ids, center: center, start: v, from: pose.scale, side: nil)
                case .side(let i): drag = .bodyScale(ids: ids, center: center, start: v, from: pose.scale, side: i)
                case .turn: drag = .bodyTurn(ids: ids, center: center, last: v, round: 0, from: pose.turn)
                case .depth(let i): drag = .bodyDepth(ids: ids, side: i, start: v, tilt: pose.tilt, swing: pose.swing)
                }
            }
        case .bead(let i):
            guard let id = handled(scene), let node = scene.board.descendant(id), let track = node[track: .move], i < track.keys.count else { return }
            // The layer goes to the key taken hold of, so the bead in hand is the layer's own middle.
            store.seek(track.keys[i].t)
            let key = track.keys[i]
            begin([id], scene)
            // Its plane at the key's moment, where the playhead now is.
            planes = [:]
            if let now = self.scene, let plane = now.board.filmMovePlane(of: id, at: now.time, pieces: now.pieces) { planes[id] = plane }
            drag = .bead(id: id, key: i, start: v, from: CGPoint(x: key.v[0], y: key.v[1]), lift: node.pose(at: key.t).lift)
        case .round(let i):
            guard let dots = cornerDots(scene) else { return }
            begin([dots.id], scene)
            drag = .round(id: dots.id, corner: i, radii: dots.radii)
        case .look:
            let under = pick(chain(at: v, in: scene), in: scene, deep: flags.contains(.command))
            drag = .look(start: v, camera: scene.camera, started: false, under: under)
        case .layer, .none:
            let chain = chain(at: v, in: scene)
            var id = pick(chain, in: scene, deep: flags.contains(.command))
            // A second click on a shape picked alone takes its points in hand; on anything else
            // picked, it goes one layer further in.
            if event.clickCount == 2, let picked = id, store.selection == [picked], chain.first?.id == picked,
               let node = scene.board.descendant(picked), node.canReshape, !node.locked {
                store.editingPath = picked
                hot = .none
                redraw()
                return
            }
            if event.clickCount == 2, let picked = id, let i = chain.firstIndex(where: { $0.id == picked }), i > 0 { id = chain[i - 1].id }
            guard let id else {
                // The bare artboard, or the table: a loop pulled round layers picks them.
                let base = flags.contains(.shift) ? store.selection : []
                if !flags.contains(.shift) {
                    // On another artboard, its film comes to the desk.
                    let p = store.viewport.toCanvas(v)
                    let other = store.seenDoc.artboards.last { !$0.hidden && $0.frame.contains(p) && $0.id != scene.board.id }
                    store.selection = other.map { [$0.id] } ?? []
                    // Beside the film, on the table, the camera is let go of, as anything picked is.
                    if store.film.camera { store.film.camera = false }
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
            pushing = DepthPushing()
        }
        hot = .none
        redraw()
    }

    /// How far a drag between two view points moves a layer in hand, as a change of its Move: the
    /// pointer cast onto the plane the layer moves along (`planes`), so the layer stays under it
    /// however that plane is turned in depth and whatever the camera. Where that has no answer
    /// (seen edge on, or past its horizon), as across a sheet lying `height` above the artboard.
    private func travel(of id: UUID, from a: CGPoint, to b: CGPoint, height: Double, in scene: Scene) -> CGPoint {
        if let d = planes[id]?.travel(from: scene.toFrame(a), to: scene.toFrame(b)) { return d }
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
        if points.dragging {
            points.drag(to: v, flags: flags)
            return
        }
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
                // Each moves along its own plane, as it stands now: worked out once, here.
                planes = [:]
                for id in from.keys {
                    if let plane = scene.board.filmMovePlane(of: id, at: scene.time, pieces: scene.pieces) { planes[id] = plane }
                }
                drag = .move(start: start, from: from, started: true)
                // Held from the press, it is lifted from where the press was.
                pushing.pointer(at: start, holding: flags.contains(.control))
            }
            // With Control held, up lifts it nearer and down lowers it, and it stays where it is
            // across; let go, it moves across again from there (`DepthPushing`, shared).
            pushing.pointer(at: v, holding: flags.contains(.control))
            let k = Double(scene.zoom * CGFloat(max(scene.camera.zoom, 0.01)))
            if pushing.pushing {
                store.pose(.lift, of: Array(from.keys)) { node in
                    guard let was = from[node.id] else { return node.value(of: .lift, at: scene.time) }
                    let h = was.lift + Double(pushing.depth) / k
                    // Caught at the artboard, or in tens with Shift.
                    if shift { return [(h / 10).rounded() * 10] }
                    return [!free && abs(h) * k <= 5 ? 0 : h.rounded()]
                }
            }
            let across = pushing.across(from: start, to: v)
            // Only lifted: no key across that says it stayed where it was.
            guard !pushing.pushed || hypot(across.x, across.y) > 0.5 || from.keys.contains(where: { tracksBefore[$0]?.contains(.move) == true }) else { break }
            let to = CGPoint(x: start.x + across.x, y: start.y + across.y)
            store.pose(.move, of: Array(from.keys)) { node in
                guard let was = from[node.id] else { return node.value(of: .move, at: scene.time) }
                var d = travel(of: node.id, from: start, to: to, height: was.lift, in: scene)
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
        case .bodyScale(let ids, let center, let start, let from, let side):
            // As one layer grows, its lead by as much; the body about its middle with it.
            var k: Double
            if let side {
                let q = body(scene)?.outline.map(scene.toView) ?? []
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
            x = max((x * 100).rounded() / 100, 0.001)
            y = max((y * 100).rounded() / 100, 0.001)
            let kx = x / max(Double(from.x), 0.001), ky = y / max(Double(from.y), 0.001)
            let t = scene.time, before = store.gestureBefore
            store.edit(MotionProperty.scale.action) { doc in doc.poseBody(ids, grownBy: kx, ky, at: t, from: before) }
        case .bodyTurn(let ids, let center, let last, var round, let from):
            round += Self.turned(v, from: last, about: center)
            drag = .bodyTurn(ids: ids, center: center, last: v, round: round, from: from)
            let degrees = Self.settled(from + round, steps: shift, free: free) - from
            let t = scene.time, before = store.gestureBefore
            store.edit(MotionProperty.turn.action) { doc in doc.poseBody(ids, turnedBy: degrees, at: t, from: before) }
        case .bodyDepth(let ids, let side, let start, let tilt, let swing):
            // The Pose card's Tilt and Swing for several: its lead to the value, the body with it.
            let (property, value) = Self.tipped(side: side, from: start, to: v, tilt: tilt, swing: swing, steps: shift, free: free)
            store.pose(property, number: 0, to: value, of: ids)
        case .bead(let id, let key, let start, let from, let lift):
            var d = travel(of: id, from: start, to: v, height: lift, in: scene)
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
        case .round(let id, let corner, let radii):
            // The pointer where it is in the rectangle's own points, through its pose and the
            // camera; then as in the design: every corner alike, or with Option only this one.
            guard let design = scene.board.descendant(id), let map = scene.board.filmPointMap(of: id, at: scene.time, pieces: scene.pieces),
                  let own = map.back(scene.toFrame(v)) else { break }
            let next = BezzleDocument.cornerRadii(at: own, frame: CGRect(origin: .zero, size: design.frame.size), rotation: 0,
                                                  corner: BezzleDocument.cornerOrder[corner], original: radii, alone: flags.contains(.option)).radii
            store.poseLooks(of: [id], "Change Corners") { $0.radii = next }
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
        if points.dragging {
            points.up(at: v, flags: flags)
            redraw()
            return
        }
        let was = drag
        drag = .none
        planes = [:]
        defer {
            hot = find(v)
            redraw()
        }
        switch was {
        case .none, .marquee:
            return
        case .move(let start, _, let started):
            guard started else { return }
            // Only lifted, it is named for that.
            let across = pushing.across(from: start, to: v)
            finish(pushing.pushed && hypot(across.x, across.y) <= 0.5 ? MotionProperty.lift.action : MotionProperty.move.action)
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
        case .bodyScale: finish(MotionProperty.scale.action)
        case .bodyTurn: finish(MotionProperty.turn.action)
        case .bodyDepth(_, let side, _, _, _): finish((side % 2 == 0 ? MotionProperty.tilt : .swing).action)
        case .bead: finish(MotionProperty.move.action)
        case .round: finish("Change Corners")
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
        planes = [:]
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
        // With a drag or two fingers in hand only Escape does anything: it puts them back. Any
        // other key would play the film under the hand, or move the playhead and have the rest of
        // one drag pose at another moment.
        if points.dragging {
            _ = points.key(event)
            return true
        }
        if dragging || !fingers.isEmpty {
            if event.keyCode == 53 { cancel() }
            return true
        }
        // A shape's points in hand: the arrows move the picked ones, Return and Escape put them
        // down. Return on a shape not in hand plays the film, as it does on anything here.
        if store.editingPath != nil, event.keyCode != 49, points.key(event) { return true }
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
            // A film that plays stops first, as under a press: what is posed or stepped from is
            // the moment it shows, not the one it was started at.
            store.pauseFilm()
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
            case "k":
                store.pauseFilm()
                store.holdHere()
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
        store.pauseFilm()
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

    /// The beads of a layer's way, in the film frame's points: like the way, the same at every
    /// moment, so worked out once for each design and kept while the playhead moves.
    private var beadsWorkedOut: (version: Int, fronts: [UUID: Int], board: UUID, id: UUID, loose: Set<UUID>, beads: [Bead])?

    /// The beads of a layer's way, where they show on screen.
    private func beads(of id: UUID, in scene: Scene) -> [Bead] {
        let loose = Set(store.posedLayers), framed: [Bead]
        if let had = beadsWorkedOut, had.version == store.version, had.fronts == store.fronts, had.board == scene.board.id, had.id == id, had.loose == loose {
            framed = had.beads
        } else {
            if let node = scene.board.descendant(id), let track = node[track: .move], track.keys.count >= 2 {
                framed = track.keys.compactMap { key in
                    scene.board.filmCorners(of: id, at: key.t, pieces: scene.pieces)
                        .map { Bead(at: Self.middle($0), time: key.t, home: MotionTiming.alike(key.v, MotionProperty.move.rest)) }
                }
            } else {
                framed = []
            }
            beadsWorkedOut = (store.version, store.fronts, scene.board.id, id, loose, framed)
        }
        return framed.map { Bead(at: scene.toView($0.at), time: $0.time, home: $0.home) }
    }

    private func outline(_ points: [CGPoint]) -> CGPath {
        let path = CGMutablePath()
        path.addLines(between: points)
        path.closeSubpath()
        return path
    }

    /// The dots inside the corners of the one picked rectangle, as the design's canvas has them
    /// (`BezzleDocument.cornerDots`), where the film shows them at the playhead: each along the
    /// diagonal as far in as its corner is round there, and never nearer the corner than ten
    /// points on screen. Dragged, a dot rounds the corners there, which keys them. Only for a
    /// rectangle the film draws by itself, big enough on screen for them not to crowd it.
    private func cornerDots(_ scene: Scene) -> (id: UUID, radii: [CGFloat], at: [CGPoint])? {
        guard let id = handled(scene), let design = scene.board.descendant(id), design.lookCount(.corners) != nil, !design.locked,
              scene.pieces.contains(where: { $0.kind == .layer && $0.layers == [id] }),
              let q = scene.corners(of: id), q.count == 4,
              let map = scene.board.filmPointMap(of: id, at: scene.time, pieces: scene.pieces) else { return nil }
        let size = design.frame.size
        let across = Self.distance(q[0], q[1]), down = Self.distance(q[1], q[2])
        guard size.width > 0, size.height > 0, across >= 48, down >= 48 else { return nil }
        // How many points on screen one of its own is, the lesser way.
        let k = min(across / size.width, down / size.height)
        let half = min(size.width, size.height) / 2
        let radii = design.looked(at: scene.time).radii
        let at = zip(BezzleDocument.cornerOrder, radii).map { h, radius -> CGPoint in
            let inset = min(max(min(max(radius, 0), half), 10 / k), half)
            let sx: CGFloat = h.unit.x == 0 ? 1 : -1, sy: CGFloat = h.unit.y == 0 ? 1 : -1
            return scene.toView(map(CGPoint(x: h.unit.x * size.width + sx * inset, y: h.unit.y * size.height + sy * inset)))
        }
        return (id, radii, at)
    }

    /// Whether the corner dots show: while the pointer is on the picked rectangle or on one of
    /// them, and while one is dragged.
    private var showsCornerDots: Bool {
        if case .round = drag { return true }
        guard case .none = drag else { return false }
        switch hot {
        case .round: return true
        case .layer(let id): return store.posedLayers == [id]
        default: return false
        }
    }

    private func drawCornerDots(_ scene: Scene, in ctx: CGContext, scale: CGFloat) {
        guard showsCornerDots, let dots = cornerDots(scene) else { return }
        for p in dots.at {
            let rect = CGRect(center: p, size: CGSize(width: 7, height: 7))
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: -0.5 * scale), blur: 1.5 * scale, color: NSColor.black.withAlphaComponent(0.18).cgColor)
            ctx.setFillColor(.white)
            ctx.fillEllipse(in: rect)
            ctx.restoreGState()
            ctx.setStrokeColor(CanvasInk.pencil.cgColor)
            ctx.setLineWidth(1)
            ctx.strokeEllipse(in: rect.insetBy(dx: 0.5, dy: 0.5))
        }
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
        // A shape whose points are in hand shows them in place of its frame.
        let editing = store.editingPath
        var shown: [UUID: [CGPoint]] = [:]
        for id in picked where id != editing {
            guard let q = scene.corners(of: id) else { continue }
            shown[id] = q
            ctx.addPath(outline(q))
            ctx.strokePath()
        }
        let moving: Bool = { if case .move(_, _, true) = drag { return true } else { return false } }()
        func handles(_ q: [CGPoint]) {
            let lengths = (0..<4).map { Self.distance(q[$0], q[($0 + 1) % 4]) }
            for i in 0..<4 where Self.carriesHandle(i, lengths) {
                drawHandle(CGPoint(x: (q[i].x + q[(i + 1) % 4].x) / 2, y: (q[i].y + q[(i + 1) % 4].y) / 2), in: ctx, scale: scale)
            }
            if Self.hasSize(lengths) { for p in q { drawHandle(p, in: ctx, scale: scale) } }
        }
        if editing != nil {
            points.draw(ctx, scale: scale)
        } else if let id = handled(scene), let q = shown[id] ?? scene.corners(of: id) {
            if !moving {
                handles(q)
                drawCornerDots(scene, in: ctx, scale: scale)
            }
        } else if !moving, let held = body(scene) {
            // Several as one body: one set of handles round it, in the plane of its lead's face.
            let q = held.outline.map(scene.toView)
            ctx.addPath(outline(q))
            ctx.strokePath()
            handles(q)
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

    /// A layer at home, as the design has it: the artboard with the layer's keys taken off, its
    /// piece there, and its corners. All of it the same at every moment, so worked out once for
    /// each design and kept while the playhead moves.
    private var homeWorkedOut: (version: Int, fronts: [UUID: Int], board: UUID, id: UUID,
                                home: (board: Node, piece: FilmPiece, layer: Node, corners: [CGPoint])?)?

    /// Where a layer's corners would show at home, as designed, through the camera as it is now.
    private func homeCorners(of id: UUID, in scene: Scene) -> [CGPoint]? {
        let home: (board: Node, piece: FilmPiece, layer: Node, corners: [CGPoint])?
        if let had = homeWorkedOut, had.version == store.version, had.fronts == store.fronts, had.board == scene.board.id, had.id == id {
            home = had.home
        } else {
            home = Self.home(of: id, on: scene.board)
            homeWorkedOut = (store.version, store.fronts, scene.board.id, id, home)
        }
        guard let home else { return nil }
        // The camera where it is now, whatever its keys say of other moments.
        let map = home.board.placement(of: home.piece, layer: home.layer, at: scene.time, camera: scene.camera).map
        return home.corners.map { scene.toView(map($0)) }
    }

    private static func home(of id: UUID, on board: Node) -> (board: Node, piece: FilmPiece, layer: Node, corners: [CGPoint])? {
        var board = board
        func strip(_ n: inout Node) {
            if n.id == id {
                for p in MotionProperty.layer { n[track: p] = nil }
                return
            }
            for i in n.children.indices { strip(&n.children[i]) }
        }
        strip(&board)
        let pieces = board.filmPieces(loose: [id])
        guard let piece = pieces.first(where: { $0.layers == [id] }), let layer = board.descendant(id),
              let way = board.way(to: id) else { return nil }
        let origin = way.dropLast().reduce(CGPoint.zero) { CGPoint(x: $0.x + $1.frame.minX, y: $0.y + $1.frame.minY) }
        let turn = BezzleDocument.turnedBox(of: layer)
        let box = layer.isGroup ? turn.frame.offsetBy(dx: origin.x, dy: origin.y) : layer.frame.offsetBy(dx: origin.x, dy: origin.y)
        return (board, piece, layer, Geometry.corners(of: box, rotation: turn.rotation))
    }

    /// The way of the layer in hand, in the film frame's points: where its middle shows at even
    /// moments from its first move key to its last, each through the camera of that moment. It
    /// changes with the design alone, not with the playhead, so it is worked out once for each
    /// design and kept while the playhead moves; each a search through the artboard, the line's
    /// two hundred points were most of a scrub's time with a moving layer picked.
    private var wayWorkedOut: (version: Int, fronts: [UUID: Int], board: UUID, id: UUID, loose: Set<UUID>, from: Double, to: Double, steps: Int, points: [CGPoint])?

    /// The picked layer's way across the artboard: a fine line through where its middle goes,
    /// ticked at even moments, so that where the ticks crowd it goes slowly; and a bead at each
    /// key, hollow where the key is the design's own place.
    private func drawWay(of id: UUID, _ ctx: CGContext, _ scene: Scene) {
        guard let node = scene.board.descendant(id), let track = node[track: .move], track.keys.count >= 2,
              let a = track.start, let b = track.end, b > a else { return }
        let steps = max(2, min(240, Int(((b - a) * 60).rounded())))
        let loose = Set(store.posedLayers), framed: [CGPoint]
        if let had = wayWorkedOut, had.version == store.version, had.fronts == store.fronts, had.board == scene.board.id, had.id == id,
           had.loose == loose, had.from == a, had.to == b, had.steps == steps {
            framed = had.points
        } else {
            framed = (0...steps).compactMap { k in
                scene.board.filmCorners(of: id, at: a + (b - a) * Double(k) / Double(steps), pieces: scene.pieces).map(Self.middle)
            }
            wayWorkedOut = (store.version, store.fronts, scene.board.id, id, loose, a, b, steps, framed)
        }
        let points = framed.map(scene.toView)
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
