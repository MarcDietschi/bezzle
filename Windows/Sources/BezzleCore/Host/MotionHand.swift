import Foundation

// The design animated, on the canvas, as the Mac's MotionTool (Canvas/MotionTool.swift, ported).
// The artboard shows its film at the playhead, through its camera; what is picked is posed there
// with the hands the canvas has everywhere: dragged to move, by a corner to grow, from just outside
// a corner to turn, from just outside the middle of a side to tip it in depth. Every pose is a key
// at the playhead, made without asking, and the first one a layer is given comes with the design
// for company, so one drag is a whole motion.
//
// The camera is picked by the small camera over the artboard's corner, or its line in the
// timeline. Picked, the artboard itself is the thing in hand, as the camera sees it: dragged to
// look elsewhere, by a corner to come closer, turned and tipped like any layer.
//
// What shows over the film comes out as marks (`marks()`), which the canvas draws.

extension WindowsCore {
    @MainActor public final class MotionHand {
        public let desk: FilmDesk
        /// Where the canvas is on the stage: a canvas point `p` is at `pan + p · zoom`.
        public var zoom: CGFloat = 1
        public var pan: CGPoint = .zero
        public var redraw: () -> Void = {}
        /// The artboard whose name is at a point on the stage.
        public var titleHit: (CGPoint) -> UUID? = { _ in nil }

        public init(desk: FilmDesk) { self.desk = desk }

        public func modeChanged() {
            // Whatever was in hand as the mode changed is put back: half a pose is no pose, and a
            // gesture left open would keep every later change out of the history.
            cancel()
            // Points in hand are the film's: the design's own are taken in hand there anew.
            points.editingPath = nil
            hot = .none
            redraw()
        }

        // MARK: A shape's points

        /// A shape's points moved at the playhead, with the pen's hands: each move poses its Shape
        /// there (`FilmPoints`). A double click on a shape, or Edit Points in the panel, takes them in hand.
        private lazy var points: FilmPoints = FilmPoints(desk: desk, view: { [unowned self] in (self.zoom, self.pan) }) { [weak self] in
            guard let scene = self?.scene else { return nil }
            return (scene.board, scene.pieces)
        }

        private lazy var pen: PenTool = {
            let tool = PenTool(host: points)
            tool.redraw = { [weak self] in self?.redraw() }
            return tool
        }()

        /// What sounds when points are moved where no pose can keep them, or Delete would take one away.
        public var beep: () -> Void {
            get { points.beep }
            set { points.beep = newValue }
        }

        /// The shape whose points are in hand: nil while none are.
        public var editingPoints: UUID? { points.editingPath }

        /// Takes the one picked shape's points in hand at the playhead, as Edit Points does; a film
        /// that plays stops first.
        public func takePoints() {
            desk.pause()
            points.editPoints()
            hot = .none
            redraw()
        }

        /// Puts the points in hand down, as Done, Return and Escape do.
        public func putPointsDown() {
            if pen.dragging { _ = pen.key(.escape, flags: []) }
            points.editingPath = nil
            redraw()
        }

        /// The Pose card's chip for what is picked: Done while its points are in hand, Edit Points
        /// otherwise, which only one layer picked can use.
        public var pointsChip: (done: Bool, enabled: Bool) { FilmPointRules.chip(editing: points.editingPath, picked: desk.posedLayers) }

        /// The window's selection changed: points in hand are put down unless their shape is the one picked.
        public func selectionChanged(_ ids: [UUID]) {
            if let editing = points.editingPath, !FilmPointRules.keeps(editing, picked: ids) { points.editingPath = nil }
        }

        /// The design changed, by an undo or by others: points of a shape that is gone, or whose
        /// outline is no longer points, are put down.
        public func designChanged() {
            if let editing = points.editingPath, WindowsCore.design?.node(editing)?.canReshape != true { points.editingPath = nil }
        }

        /// The lines the point being moved catches on, on the canvas.
        public var guideLines: [GuideLine] { Pen.lines(points.guides) }

        private static func penFlags(shift: Bool, option: Bool = false, command: Bool = false) -> PenFlags {
            var f: PenFlags = []
            if shift { f.insert(.shift) }
            if option { f.insert(.option) }
            if command { f.insert(.command) }
            return f
        }

        private static func penKey(_ name: String) -> PenKey {
            switch name {
            case "escape": .escape
            case "enter": .enter
            case "delete", "backspace": .delete
            case "left": .left
            case "right": .right
            case "up": .up
            case "down": .down
            default: .other
            }
        }

        // MARK: The film as it lies on the canvas

        struct Scene {
            var board: Node
            var pieces: [FilmPiece]
            var time: Double
            var camera: FilmCamera
            /// The film's frame, on the stage.
            var rect: CGRect
            var zoom: CGFloat

            func toView(_ p: CGPoint) -> CGPoint { CGPoint(x: rect.minX + p.x * zoom, y: rect.minY + p.y * zoom) }
            func toFrame(_ v: CGPoint) -> CGPoint { CGPoint(x: (v.x - rect.minX) / zoom, y: (v.y - rect.minY) / zoom) }
            var size: CGSize { board.frame.size }
            func ground(height: Double = 0) -> FilmMap { FilmLens.ground(camera, size: size, height: height) }
            func corners(of id: UUID) -> [CGPoint]? { board.filmCorners(of: id, at: time, pieces: pieces)?.map(toView) }
            var sheet: [CGPoint] {
                let map = ground()
                let s = size
                return [CGPoint.zero, CGPoint(x: s.width, y: 0), CGPoint(x: s.width, y: s.height), CGPoint(x: 0, y: s.height)].map { toView(map($0)) }
            }
        }

        private var piecesWorkedOut: (version: Int, board: UUID, loose: Set<UUID>, fronts: [UUID: Int], pieces: [FilmPiece])?

        var scene: Scene? {
            guard let board = desk.filmBoard else { return nil }
            let loose = Set(desk.posedLayers)
            let pieces: [FilmPiece]
            if let had = piecesWorkedOut, had.version == WindowsCore.designVersion, had.board == board.id, had.loose == loose, had.fronts == WindowsCore.fronts {
                pieces = had.pieces
            } else {
                pieces = board.filmPieces(loose: loose)
                piecesWorkedOut = (WindowsCore.designVersion, board.id, loose, WindowsCore.fronts, pieces)
            }
            let t = desk.filmTime
            let f = board.frame
            let rect = CGRect(x: pan.x + f.minX * zoom, y: pan.y + f.minY * zoom, width: f.width * zoom, height: f.height * zoom)
            return Scene(board: board, pieces: pieces, time: t, camera: board.camera(at: t), rect: rect, zoom: zoom)
        }

        // MARK: What the pointer is on

        enum Grip: Equatable {
            case corner(Int), side(Int), turn(Int), depth(Int)
        }

        private enum Hot: Equatable {
            case none
            case layer(UUID)
            case grip(Grip)
            case bead(Int)
            case cameraChip
            case look
        }

        private var hot: Hot = .none
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

        private func grip(at v: CGPoint, on q: [CGPoint], sides: Bool) -> Grip? {
            guard q.count == 4 else { return nil }
            let mids = (0..<4).map { i in CGPoint(x: (q[i].x + q[(i + 1) % 4].x) / 2, y: (q[i].y + q[(i + 1) % 4].y) / 2) }
            let lengths = (0..<4).map { Self.distance(q[$0], q[($0 + 1) % 4]) }
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

        private static func carriesHandle(_ i: Int, _ lengths: [CGFloat]) -> Bool {
            lengths[i] >= 30 && lengths[(i + 1) % 4] >= 16
        }

        /// The one layer whose handles show: the only one picked.
        private func handled(_ scene: Scene) -> UUID? {
            let ids = desk.posedLayers
            return ids.count == 1 && !desk.camera ? ids[0] : nil
        }

        private func chipRect(_ scene: Scene) -> CGRect {
            CGRect(x: scene.rect.maxX - 22, y: scene.rect.minY - 21, width: 22, height: 18)
        }

        private func chipShows(_ scene: Scene) -> Bool { scene.rect.width >= 60 }

        private func chain(at v: CGPoint, in scene: Scene) -> [Node] {
            guard scene.rect.contains(v) else { return [] }
            let tolerance = 3 / scene.zoom
            return scene.board.filmChain(at: scene.toFrame(v), time: scene.time, pieces: scene.pieces, tolerance: tolerance)
        }

        private func pick(_ chain: [Node], in scene: Scene, deep: Bool) -> UUID? {
            let ids = chain.map(\.id)
            guard !ids.isEmpty else { return nil }
            if deep { return ids[0] }
            if let picked = desk.selection.first, let way = scene.board.way(to: picked) {
                for holder in way.dropLast().reversed() {
                    if let i = ids.firstIndex(of: holder.id), i > 0 { return ids[i - 1] }
                }
                if ids.contains(picked) { return picked }
            }
            return ids.last
        }

        private func find(_ v: CGPoint) -> Hot {
            guard let scene, !desk.playing else { return .none }
            if chipShows(scene), chipRect(scene).insetBy(dx: -3, dy: -3).contains(v) { return .cameraChip }
            if desk.camera {
                if let g = grip(at: v, on: scene.sheet, sides: false) { return .grip(g) }
                return scene.rect.contains(v) ? .look : .none
            }
            if let id = handled(scene), let q = scene.corners(of: id) {
                let g = grip(at: v, on: q, sides: true)
                if let g {
                    switch g {
                    case .corner, .side: return .grip(g)
                    case .turn, .depth: break
                    }
                }
                let here = Self.middle(q)
                for (i, bead) in beads(of: id, in: scene).enumerated() where Self.distance(v, bead.at) <= 7 && Self.distance(bead.at, here) > 1 { return .bead(i) }
                if let g, !chain(at: v, in: scene).contains(where: { $0.id == id }) { return .grip(g) }
            }
            if let id = pick(chain(at: v, in: scene), in: scene, deep: false) { return .layer(id) }
            return .none
        }

        public func hover(_ v: CGPoint?) {
            if points.editingPath != nil { pen.hover(v, flags: []) }
            guard case .none = drag else { return }
            let next = v.map(find) ?? .none
            if next != hot {
                hot = next
                redraw()
            }
        }

        /// The pointer the canvas shows at a point on the stage.
        public enum Pointer: Equatable { case arrow, resize(Double), rotate(Double), turn, cross, pointingHand, grab, grabbing }

        public func pointer(at v: CGPoint) -> Pointer {
            // A shape's points in hand: the arrow, on them and off, as the Mac's pen has it there.
            if points.editingPath != nil { return .arrow }
            guard let scene else { return .arrow }
            let found = dragging ? held : find(v)
            switch found {
            case .grip(let g):
                let q = desk.camera ? scene.sheet : handled(scene).flatMap { scene.corners(of: $0) } ?? []
                guard q.count == 4 else { return .arrow }
                let c = Self.middle(q)
                func angle(_ p: CGPoint) -> Double { Double(atan2(p.y - c.y, p.x - c.x)) * 180 / .pi }
                switch g {
                case .corner(let i): return .resize(angle(q[i]))
                case .side(let i): return .resize(angle(CGPoint(x: (q[i].x + q[(i + 1) % 4].x) / 2, y: (q[i].y + q[(i + 1) % 4].y) / 2)))
                case .turn(let i): return .rotate(angle(q[i]))
                case .depth: return .turn
                }
            case .bead: return .cross
            case .cameraChip: return .pointingHand
            case .look:
                if case .look = drag { return .grabbing }
                return .grab
            case .layer, .none: return .arrow
            }
        }

        // MARK: Dragging

        private enum Drag {
            case none
            case move(start: CGPoint, from: [UUID: (move: CGPoint, lift: Double)], started: Bool)
            case scale(id: UUID, center: CGPoint, start: CGPoint, from: CGPoint, side: Int?)
            case turn(id: UUID, center: CGPoint, last: CGPoint, round: Double, from: Double)
            case depth(id: UUID, side: Int, start: CGPoint, tilt: Double, swing: Double)
            case bead(id: UUID, key: Int, start: CGPoint, from: CGPoint, lift: Double)
            case look(start: CGPoint, camera: FilmCamera, started: Bool, under: UUID?)
            case zoom(center: CGPoint, start: CGPoint, from: Double)
            case roll(center: CGPoint, last: CGPoint, round: Double, from: Double)
            case tip(side: Int, start: CGPoint, tilt: Double, swing: Double)
            case marquee(start: CGPoint, now: CGPoint, base: [UUID])
        }

        private var drag: Drag = .none
        /// A move with Alt held lifts what is dragged instead (the shared `DepthPushing`), in view
        /// points, as Control does on the Mac.
        private var pushing = DepthPushing()
        private var tracksBefore: [UUID: Set<MotionProperty>] = [:]

        public var dragging: Bool {
            if pen.dragging { return true }
            if case .none = drag { return false } else { return true }
        }

        private func begin(_ ids: [UUID], _ scene: Scene) {
            tracksBefore = [:]
            for id in ids {
                let node = id == scene.board.id ? scene.board : scene.board.descendant(id)
                tracksBefore[id] = Set(node?.motionProperties ?? [])
            }
            WindowsCore.beginGesture()
        }

        /// A press at a point on the stage. `deep` (Ctrl) picks the topmost layer, through groups.
        public func down(at v: CGPoint, clicks: Int, shift: Bool, deep: Bool) {
            // A press ends a pinch still held to be going on.
            pinchEnded()
            if desk.playing {
                let looking = desk.looking
                desk.pause()
                if !looking { return }
            }
            if let title = titleHit(v) {
                desk.select([title])
                return
            }
            guard let scene else {
                // No film on the desk: a press on an artboard brings that one's.
                let p = CGPoint(x: (v.x - pan.x) / zoom, y: (v.y - pan.y) / zoom)
                let under = WindowsCore.design?.artboards.last { !$0.hidden && $0.frame.contains(p) }
                desk.select(under.map { [$0.id] } ?? [])
                desk.focus()
                redraw()
                return
            }
            // A shape's points in hand: pressed on, they move; off them, a loop round some, or out
            // of editing to whatever was pressed. A double click off them puts them down.
            if let editing = points.editingPath {
                if pen.editDown(at: v, flags: Self.penFlags(shift: shift, command: deep), clicks: clicks) {
                    redraw()
                    return
                }
                let other = pick(chain(at: v, in: scene), in: scene, deep: deep)
                switch FilmPointRules.press(on: other, editing: editing, clicks: clicks) {
                case .putDown:
                    points.editingPath = nil
                    redraw()
                    return
                case .loop(let leaves):
                    pen.startMarquee(at: v, adding: shift, offPath: leaves)
                    redraw()
                    return
                case .passOn:
                    points.editingPath = nil
                }
            }
            held = find(v)
            switch held {
            case .cameraChip:
                if desk.camera { desk.camera = false } else { desk.pickCamera() }
            case .grip(let g):
                if desk.camera {
                    let center = CGPoint(x: scene.rect.midX, y: scene.rect.midY)
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
                desk.seek(track.keys[i].t)
                let key = track.keys[i]
                begin([id], scene)
                drag = .bead(id: id, key: i, start: v, from: CGPoint(x: key.v[0], y: key.v[1]), lift: node.pose(at: key.t).lift)
            case .look:
                let under = pick(chain(at: v, in: scene), in: scene, deep: deep)
                drag = .look(start: v, camera: scene.camera, started: false, under: under)
            case .layer, .none:
                let chain = chain(at: v, in: scene)
                var id = pick(chain, in: scene, deep: deep)
                // A second click on a shape picked alone takes its points in hand; on anything else
                // picked, it goes one layer further in.
                if let picked = id, let node = scene.board.descendant(picked),
                   FilmPointRules.takesInHand(clicks: clicks, pressed: picked, selection: desk.selection, deepest: chain.first?.id,
                                              reshapes: node.canReshape, locked: node.locked) {
                    points.editingPath = picked
                    hot = .none
                    redraw()
                    return
                }
                if clicks == 2, let picked = id, let i = chain.firstIndex(where: { $0.id == picked }), i > 0 { id = chain[i - 1].id }
                guard let id else {
                    let base = shift ? desk.selection : []
                    if !shift {
                        let p = CGPoint(x: (v.x - pan.x) / zoom, y: (v.y - pan.y) / zoom)
                        let other = WindowsCore.design?.artboards.last { !$0.hidden && $0.frame.contains(p) && $0.id != scene.board.id }
                        desk.select(other.map { [$0.id] } ?? [])
                        if desk.camera { desk.camera = false }
                    }
                    drag = .marquee(start: v, now: v, base: base)
                    return
                }
                if shift {
                    var picked = desk.selection
                    if picked.contains(id) { picked.removeAll { $0 == id } } else { picked.append(id) }
                    desk.select(picked)
                    return
                }
                if !desk.selection.contains(id) { desk.select([id]) }
                guard let now = self.scene else { return }
                var from: [UUID: (move: CGPoint, lift: Double)] = [:]
                for picked in desk.posedLayers {
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

        private func travel(from a: CGPoint, to b: CGPoint, height: Double, in scene: Scene) -> CGPoint {
            let map = scene.ground(height: height)
            if let p = map.back(scene.toFrame(a)), let q = map.back(scene.toFrame(b)) { return CGPoint(x: q.x - p.x, y: q.y - p.y) }
            let k = scene.zoom * CGFloat(max(scene.camera.zoom, 0.01))
            return CGPoint(x: (b.x - a.x) / k, y: (b.y - a.y) / k)
        }

        private static func caught(_ x: Double, at stop: Double, within reach: Double) -> Double {
            abs(x - stop) <= reach ? stop : x
        }

        private static func degrees(_ p: CGPoint, about c: CGPoint) -> Double {
            Double(atan2(p.y - c.y, p.x - c.x)) * 180 / .pi
        }

        private static func turned(_ p: CGPoint, from start: CGPoint, about c: CGPoint) -> Double {
            var d = degrees(p, about: c) - degrees(start, about: c)
            while d > 180 { d -= 360 }
            while d < -180 { d += 360 }
            return d
        }

        private static func settled(_ degrees: Double, steps: Bool, free: Bool) -> Double {
            if steps { return (degrees / 15).rounded() * 15 }
            if free { return degrees }
            let whole = degrees.rounded(), straight = (whole / 360).rounded() * 360
            return abs(whole - straight) <= 2 ? straight : whole
        }

        /// The press moved on. `free` (Ctrl) lets go of everything a pose catches on; `push` (Alt)
        /// held while a layer is moved lifts it nearer as the pointer goes up, and lowers it as it
        /// goes down, leaving it where it is across.
        public func drag(to v: CGPoint, shift: Bool, free: Bool, push: Bool = false) {
            // The points' own hands: Ctrl lets go of what they catch on, Alt moves a handle alone.
            if pen.dragging {
                pen.drag(to: v, flags: Self.penFlags(shift: shift, option: push, command: free))
                redraw()
                return
            }
            guard let scene else { return }
            switch drag {
            case .none:
                break
            case .move(let start, let from, var started):
                if !started {
                    guard Self.distance(v, start) >= 3 else { return }
                    started = true
                    begin(Array(from.keys), scene)
                    drag = .move(start: start, from: from, started: true)
                    // Held from the press, it is lifted from where the press was.
                    pushing.pointer(at: start, holding: push)
                }
                pushing.pointer(at: v, holding: push)
                let k = Double(scene.zoom * CGFloat(max(scene.camera.zoom, 0.01)))
                let pushed = pushing, across = pushing.across(from: start, to: v)
                // Only lifted: no key across that says it stayed where it was.
                let moves = !pushed.pushed || hypot(across.x, across.y) > 0.5 || from.keys.contains { tracksBefore[$0]?.contains(.move) == true }
                let to = CGPoint(x: start.x + across.x, y: start.y + across.y)
                // One change for both: inside the gesture each change is made again from where it
                // began, so the height stays posed once Alt is let go.
                desk.pose(of: Array(from.keys)) { node in
                    guard let was = from[node.id] else { return [] }
                    var out: [(MotionProperty, [Double])] = []
                    if pushed.pushed {
                        let h = was.lift + Double(pushed.depth) / k
                        // Caught at the artboard, or in tens with Shift.
                        out.append((.lift, [shift ? (h / 10).rounded() * 10 : (!free && abs(h) * k <= 5 ? 0 : h.rounded())]))
                    }
                    guard moves else { return out }
                    var d = travel(from: start, to: to, height: was.lift, in: scene)
                    if shift { if abs(d.x) >= abs(d.y) { d.y = 0 } else { d.x = 0 } }
                    var x = Double(was.move.x + d.x), y = Double(was.move.y + d.y)
                    if !free {
                        let reach = 5 / k
                        x = Self.caught(x, at: 0, within: reach)
                        y = Self.caught(y, at: 0, within: reach)
                    }
                    out.append((.move, [(x * 2).rounded() / 2, (y * 2).rounded() / 2]))
                    return out
                }
            case .scale(let id, let center, let start, let from, let side):
                var k: Double
                if let side {
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
                desk.pose(.scale, of: [id]) { _ in [(x * 100).rounded() / 100, (y * 100).rounded() / 100] }
            case .turn(let id, let center, let last, var round, let from):
                round += Self.turned(v, from: last, about: center)
                drag = .turn(id: id, center: center, last: v, round: round, from: from)
                let degrees = Self.settled(from + round, steps: shift, free: free)
                desk.pose(.turn, of: [id]) { _ in [degrees] }
            case .depth(let id, let side, let start, let tilt, let swing):
                let (property, value) = Self.tipped(side: side, from: start, to: v, tilt: tilt, swing: swing, steps: shift, free: free)
                desk.pose(property, of: [id]) { _ in [value] }
            case .bead(let id, let key, let start, let from, let lift):
                var d = travel(from: start, to: v, height: lift, in: scene)
                if shift { if abs(d.x) >= abs(d.y) { d.y = 0 } else { d.x = 0 } }
                var x = Double(from.x + d.x), y = Double(from.y + d.y)
                if !free {
                    let reach = 5 / Double(scene.zoom * CGFloat(max(scene.camera.zoom, 0.01)))
                    x = Self.caught(x, at: 0, within: reach)
                    y = Self.caught(y, at: 0, within: reach)
                }
                let before = WindowsCore.design
                WindowsCore.edit { doc in
                    doc.update(id) { n in
                        guard var track = n[track: .move], key < track.keys.count else { return }
                        track.keys[key].v = [(x * 2).rounded() / 2, (y * 2).rounded() / 2]
                        track.keys[key].given = nil
                        n[track: .move] = track
                    }
                }
                if WindowsCore.design != before { desk.edited() }
            case .look(let start, let camera, var started, let under):
                if !started {
                    guard Self.distance(v, start) >= 3 else { return }
                    started = true
                    begin([scene.board.id], scene)
                    drag = .look(start: start, camera: camera, started: true, under: under)
                }
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
                desk.poseCamera(.cameraMove, [x.rounded(), y.rounded()])
            case .zoom(let center, let start, let from):
                var zoom = from * Double(Self.distance(v, center) / max(Self.distance(start, center), 1))
                if !free { zoom = Self.caught(zoom, at: 1, within: 0.03) }
                desk.poseCamera(.cameraZoom, [(zoom * 100).rounded() / 100])
            case .roll(let center, let last, var round, let from):
                round += Self.turned(v, from: last, about: center)
                drag = .roll(center: center, last: v, round: round, from: from)
                desk.poseCamera(.cameraRoll, [Self.settled(from + round, steps: shift, free: free)])
            case .tip(let side, let start, let tilt, let swing):
                let (property, value) = Self.tipped(side: side, from: start, to: v, tilt: tilt, swing: swing, steps: shift, free: free)
                desk.poseCamera(property == .tilt ? .cameraTilt : .cameraSwing, [value])
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
                if ids != desk.selection { desk.select(ids) }
            }
            redraw()
        }

        private static func tipped(side: Int, from start: CGPoint, to v: CGPoint, tilt: Double, swing: Double, steps: Bool, free: Bool) -> (MotionProperty, Double) {
            let rate = 0.6
            let property: MotionProperty = side % 2 == 0 ? .tilt : .swing
            var value = side % 2 == 0 ? tilt + Double(v.y - start.y) * rate : swing - Double(v.x - start.x) * rate
            if steps { value = (value / 15).rounded() * 15 } else if !free { value = caught(value.rounded(), at: 0, within: 3) }
            return (property, value)
        }

        public func up(at v: CGPoint, shift: Bool = false) {
            if pen.dragging {
                pen.up(at: v, flags: Self.penFlags(shift: shift))
                redraw()
                return
            }
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
                finish()
            case .look(_, _, let started, let under):
                guard started else {
                    if let under { desk.select([under]) }
                    return
                }
                finish()
            case .scale, .turn, .depth, .bead, .zoom, .roll, .tip:
                finish()
            }
        }

        /// Ends a drag as one step, and where it gave something its first key, shows the motion
        /// that made: once through, and the playhead back where it was.
        private func finish() {
            let before = tracksBefore
            tracksBefore = [:]
            if WindowsCore.inGesture {
                // Let go where the design has it, something that had no keys is given none. Made
                // on top of the drag as it stands, not again from where it began.
                Editing.gestureBase = WindowsCore.design
                let was = WindowsCore.design
                WindowsCore.edit { doc in
                    for (id, had) in before {
                        doc.update(id) { n in
                            for p in n.motionProperties where !had.contains(p) {
                                guard let track = n[track: p], track.keys.allSatisfy({ MotionTiming.alike($0.v, p.rest) }) else { continue }
                                n[track: p] = nil
                            }
                        }
                    }
                }
                _ = was
            }
            WindowsCore.endGesture()
            desk.edited()
            guard let board = desk.filmBoard else { return }
            let t = desk.filmTime
            var span: (from: Double, to: Double)?
            for (id, had) in before {
                guard let node = id == board.id ? board : board.descendant(id) else { continue }
                for p in node.motionProperties where !had.contains(p) {
                    guard let track = node[track: p], let a = track.start, let b = track.end, b > a else { continue }
                    span = (min(span?.from ?? a, a), max(span?.to ?? b, b))
                }
            }
            if let span { desk.show(from: span.from, to: span.to, back: t) }
        }

        // MARK: Two fingers on the camera

        /// A pinch going on as the camera's, and how close it has brought it so far.
        private var pinched: Double?
        /// A pinch put back with Escape while it went on: what is left of it is swallowed.
        private var pinchSpent = false
        public var pinching: Bool { pinched != nil || pinchSpent }

        /// Two fingers pinched on a touchpad, at a point on the stage: the camera comes closer by
        /// `factor`, or draws back, as on the Mac (MotionTool.magnify). False where the pinch is
        /// the view's: only with the camera picked, nothing else in hand and the pointer on its
        /// film is it the camera's, and it stays what it was when it began. Windows says neither
        /// where a pinch begins nor where it ends, so whoever tells of it says when no more of it
        /// came for a moment (`pinchEnded`): from first to last it poses the camera as one step.
        public func pinch(by factor: Double, at v: CGPoint) -> Bool {
            if pinchSpent { return true }
            if pinched == nil {
                guard desk.camera, !desk.playing, !dragging, let scene, scene.rect.contains(v) else { return false }
                begin([scene.board.id], scene)
                pinched = scene.camera.zoom
            }
            guard let now = pinched, factor.isFinite, factor > 0 else { return true }
            // Within what a camera's zoom may be (`MotionProperty.cameraZoom`).
            let next = min(max(now * factor, 0.1), 16)
            pinched = next
            desk.poseCamera(.cameraZoom, [next])
            redraw()
            return true
        }

        /// No more of a pinch came: what it did to the camera is one step.
        public func pinchEnded() {
            let was = pinched
            pinched = nil
            pinchSpent = false
            guard was != nil else { return }
            finish()
            redraw()
        }

        @discardableResult
        public func cancel() -> Bool {
            // A pinch put back: the camera where it was, and the rest of the pinch does nothing.
            if pinched != nil {
                pinched = nil
                pinchSpent = true
                if WindowsCore.inGesture {
                    WindowsCore.cancelGesture()
                    desk.edited()
                }
                tracksBefore = [:]
                redraw()
                return true
            }
            guard dragging else { return false }
            // The points' drag put back as Escape puts it back, with the pen's own drag let go.
            if pen.dragging {
                _ = pen.key(.escape, flags: [])
                redraw()
                return true
            }
            if WindowsCore.inGesture {
                WindowsCore.cancelGesture()
                desk.edited()
            }
            drag = .none
            tracksBefore = [:]
            redraw()
            return true
        }

        // MARK: Keys

        /// A key while the design is animated, by name ("enter", "delete", "escape", "home",
        /// "end", "left", "right", "up", "down", or the letter typed). Delete takes keys away,
        /// never layers; Enter plays from the start; the arrows nudge what is picked, or with
        /// nothing picked step through time, with Alt from key to key. True when it was the film's.
        public func key(_ name: String, shift: Bool, alt: Bool, ctrl: Bool) -> Bool {
            if pen.dragging {
                _ = pen.key(Self.penKey(name), flags: Self.penFlags(shift: shift))
                redraw()
                return true
            }
            // With a drag or a pinch in hand only Escape does anything: it puts them back.
            if dragging || pinched != nil {
                if name == "escape" { cancel() }
                return true
            }
            // A shape's points in hand: the arrows move the picked ones, Enter and Escape put them
            // down, Delete takes none away. Enter on a shape not in hand plays the film, as it
            // does on anything here.
            if points.editingPath != nil, !ctrl, !alt, pen.key(Self.penKey(name), flags: Self.penFlags(shift: shift)) {
                redraw()
                return true
            }
            switch name {
            case "enter":
                guard !ctrl, !alt else { return false }
                desk.play(fromStart: true)
            case "delete", "backspace":
                guard !ctrl, !alt else { return false }
                desk.removeKeys()
            case "escape":
                if cancel() { return true }
                if desk.playing { desk.pause() } else if !desk.keys.isEmpty { desk.keys = [] }
                else if desk.camera { desk.camera = false } else { desk.select([]) }
            case "home":
                desk.seek(0)
            case "end":
                desk.seek(desk.filmBoard?.filmLength ?? 0)
            case "left", "right", "up", "down":
                guard !ctrl else { return false }
                desk.pause()
                let dx: Double = name == "left" ? -1 : name == "right" ? 1 : 0
                let dy: Double = name == "up" ? -1 : name == "down" ? 1 : 0
                if alt, dx != 0 {
                    desk.stepToKey(forward: dx > 0)
                    return true
                }
                let step: Double = shift ? 10 : 1
                let ids = desk.posedLayers
                if desk.camera, let scene {
                    desk.poseCamera(.cameraMove, [scene.camera.x + dx * step, scene.camera.y + dy * step])
                } else if !ids.isEmpty, let scene {
                    desk.pose(.move, of: ids) { node in
                        let was = node.value(of: .move, at: scene.time)
                        return [was[0] + dx * step, was[1] + dy * step]
                    }
                } else if dx != 0 {
                    desk.stepFrames(Int(dx) * (shift ? 10 : 1))
                }
            case ",":
                guard !ctrl, !alt else { return false }
                desk.stepFrames(shift ? -10 : -1)
            case ".":
                guard !ctrl, !alt else { return false }
                desk.stepFrames(shift ? 10 : 1)
            case "k":
                guard !ctrl, !alt else { return false }
                desk.pause()
                desk.holdHere()
            default:
                return false
            }
            redraw()
            return true
        }

        // MARK: Right click

        /// One entry of the right-click menu: its words, its shortcut, a tick, whether it can be
        /// chosen, and what it does.
        public struct MenuItem {
            public let title: String
            public let shortcut: String?
            public let checked: Bool
            public let enabled: Bool
            public let action: (@MainActor () -> Void)?
            /// A line between entries.
            public var isSeparator: Bool { action == nil && title.isEmpty }
            static let separator = MenuItem(title: "", shortcut: nil, checked: false, enabled: false, action: nil)
        }

        public func menu(at v: CGPoint) -> [MenuItem]? {
            guard let scene, !desk.playing else { return nil }
            if !desk.camera, let id = pick(chain(at: v, in: scene), in: scene, deep: false), !desk.selection.contains(id) {
                desk.select([id])
            }
            let desk = desk
            let some = desk.camera || !desk.posedLayers.isEmpty
            var entries: [MenuItem] = []
            if some {
                entries.append(MenuItem(title: WindowsCore.say("Hold Here"), shortcut: "K", checked: false, enabled: true) { desk.holdHere() })
                entries.append(MenuItem(title: WindowsCore.say("Remove Key"), shortcut: WindowsCore.say("Delete"), checked: false, enabled: desk.hasKeysToRemove) { desk.removeKeys() })
                if desk.hasKeysToRemove {
                    entries.append(.separator)
                    let shared = desk.sharedEase
                    for pace in FilmDesk.paces {
                        entries.append(MenuItem(title: pace.title, shortcut: nil, checked: shared == pace.name, enabled: true) { desk.setEase(pace.name) })
                    }
                }
                entries.append(.separator)
            }
            entries.append(MenuItem(title: WindowsCore.say(some ? "Remove Motion" : "Remove All Motion"), shortcut: nil, checked: false,
                                    enabled: some ? true : scene.board.hasFilm) { desk.clearMotion() })
            entries.append(.separator)
            entries.append(MenuItem(title: WindowsCore.say(desk.playing ? "Pause" : "Play"), shortcut: WindowsCore.say("Space"), checked: false, enabled: true) { desk.toggle() })
            return entries
        }

        // MARK: What shows

        private struct Bead {
            var at: CGPoint
            var time: Double
            var home: Bool
        }

        /// The beads of a layer's way, in the film frame's points: like the way, the same at every
        /// moment, so worked out once for each design and kept while the playhead moves.
        private var beadsWorkedOut: (version: Int, fronts: [UUID: Int], board: UUID, id: UUID, loose: Set<UUID>, beads: [Bead])?

        /// The beads of a layer's way, where they show on the stage.
        private func beads(of id: UUID, in scene: Scene) -> [Bead] {
            let loose = Set(desk.posedLayers), framed: [Bead]
            if let had = beadsWorkedOut, had.version == WindowsCore.designVersion, had.fronts == WindowsCore.fronts, had.board == scene.board.id,
               had.id == id, had.loose == loose {
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
                beadsWorkedOut = (WindowsCore.designVersion, WindowsCore.fronts, scene.board.id, id, loose, framed)
            }
            return framed.map { Bead(at: scene.toView($0.at), time: $0.time, home: $0.home) }
        }

        /// What shows over the film on the stage, as the Mac's MotionTool draws it.
        public struct Marks {
            /// The film's frame on the stage.
            public var frame: CGRect = .zero
            /// The small camera over the artboard's corner: where, and whether it is picked,
            /// pointed at, and has keys.
            public var chip: CGRect?
            public var chipOn = false, chipHot = false, chipKeys = false
            /// Where what is picked belongs, while it is elsewhere: dashed.
            public var homes: [[CGPoint]] = []
            /// The layer pointed at, 1.5 wide.
            public var hovered: [CGPoint]?
            /// What is picked, 1 wide.
            public var picked: [[CGPoint]] = []
            /// The handles of the one picked: square, white.
            public var handles: [CGPoint] = []
            /// Its way across the artboard: the line, its ticks a twentieth of a second apart, and
            /// a bead at each key, hollow where the key is the design's own place, larger where
            /// pointed at or at the playhead.
            public var way: [CGPoint] = []
            public var ticks: [CGPoint] = []
            public var beads: [(at: CGPoint, home: Bool, large: Bool)] = []
            /// The camera in hand: the frame dashed, the artboard as it sees it, a cross at the
            /// middle, and its corners' handles.
            public var camera = false
            public var sheet: [CGPoint] = []
            /// A loop being pulled round layers.
            public var marquee: CGRect?
            /// A shape's points in hand, as the pen shows them: in place of its frame and handles.
            public var points: Pen.Overlay?
            /// Nothing at all lies over a film that plays but the small camera.
            public var playing = false
        }

        public func marks() -> Marks? { Probe.time("marks.core") { marksMade() } }

        private func marksMade() -> Marks? {
            guard let scene else { return nil }
            var m = Marks()
            m.frame = scene.rect
            if chipShows(scene) {
                m.chip = chipRect(scene)
                m.chipOn = desk.camera
                m.chipHot = hot == .cameraChip
                m.chipKeys = scene.board.hasCamera
            }
            guard !desk.playing else {
                m.playing = true
                return m
            }
            if desk.camera {
                m.camera = true
                m.sheet = scene.sheet
                m.handles = scene.sheet
                return m
            }
            let picked = desk.posedLayers
            for id in picked {
                guard let node = scene.board.descendant(id), !node.pose(at: scene.time).isRest, let home = homeCorners(of: id, in: scene) else { continue }
                m.homes.append(home)
            }
            if let id = handled(scene) { way(of: id, scene, into: &m) }
            if case .layer(let id) = hot, !picked.contains(id), let q = scene.corners(of: id) { m.hovered = q }
            // A shape whose points are in hand shows them in place of its frame.
            let editing = points.editingPath
            var outlined: [UUID: [CGPoint]] = [:]
            for id in picked where id != editing {
                if let q = scene.corners(of: id) {
                    outlined[id] = q
                    m.picked.append(q)
                }
            }
            if editing != nil {
                m.points = Pen.overlay(pen.overlay(), zoom: zoom, pan: pan)
            } else if let id = handled(scene), let q = outlined[id] ?? scene.corners(of: id) {
                let moving: Bool = { if case .move(_, _, true) = drag { return true } else { return false } }()
                if !moving {
                    let lengths = (0..<4).map { Self.distance(q[$0], q[($0 + 1) % 4]) }
                    for i in 0..<4 where Self.carriesHandle(i, lengths) {
                        m.handles.append(CGPoint(x: (q[i].x + q[(i + 1) % 4].x) / 2, y: (q[i].y + q[(i + 1) % 4].y) / 2))
                    }
                    if Self.hasSize(lengths) { m.handles += q }
                }
            }
            if case .marquee(let start, let now, _) = drag { m.marquee = Geometry.rect(from: start, to: now) }
            return m
        }

        /// A layer at home, as the design has it: the artboard with the layer's keys taken off,
        /// its piece there, and its corners. All of it the same at every moment, so worked out once
        /// for each design and kept while the playhead moves.
        private var homeWorkedOut: (version: Int, fronts: [UUID: Int], board: UUID, id: UUID,
                                    home: (board: Node, piece: FilmPiece, layer: Node, corners: [CGPoint])?)?

        /// Where a layer's corners would show at home, as designed, through the camera as it is now.
        private func homeCorners(of id: UUID, in scene: Scene) -> [CGPoint]? {
            let home: (board: Node, piece: FilmPiece, layer: Node, corners: [CGPoint])?
            if let had = homeWorkedOut, had.version == WindowsCore.designVersion, had.fronts == WindowsCore.fronts, had.board == scene.board.id, had.id == id {
                home = had.home
            } else {
                home = Self.home(of: id, on: scene.board)
                homeWorkedOut = (WindowsCore.designVersion, WindowsCore.fronts, scene.board.id, id, home)
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

        /// The way of the layer in hand, in the film frame's points: where its middle shows at
        /// even moments from its first move key to its last, each through the camera of that
        /// moment. It changes with the design alone, not with the playhead, so it is worked out
        /// once for each design and kept while the playhead moves: each point a search through
        /// the artboard, the line's two hundred points were most of a scrub's time with a moving
        /// layer picked.
        private var wayWorkedOut: (version: Int, fronts: [UUID: Int], board: UUID, id: UUID, loose: Set<UUID>, from: Double, to: Double, steps: Int, points: [CGPoint])?

        private func way(of id: UUID, _ scene: Scene, into m: inout Marks) {
            guard let node = scene.board.descendant(id), let track = node[track: .move], track.keys.count >= 2,
                  let a = track.start, let b = track.end, b > a else { return }
            let steps = max(2, min(240, Int(((b - a) * 60).rounded())))
            let loose = Set(desk.posedLayers), framed: [CGPoint]
            if let had = wayWorkedOut, had.version == WindowsCore.designVersion, had.fronts == WindowsCore.fronts, had.board == scene.board.id,
               had.id == id, had.loose == loose, had.from == a, had.to == b, had.steps == steps {
                framed = had.points
            } else {
                framed = (0...steps).compactMap { k in
                    scene.board.filmCorners(of: id, at: a + (b - a) * Double(k) / Double(steps), pieces: scene.pieces).map(Self.middle)
                }
                wayWorkedOut = (WindowsCore.designVersion, WindowsCore.fronts, scene.board.id, id, loose, a, b, steps, framed)
            }
            let points = framed.map(scene.toView)
            guard points.count >= 2 else { return }
            m.way = points
            let every = max(1, Int((Double(steps) / ((b - a) * 20)).rounded()))
            for (k, p) in points.enumerated() where k % every == 0 && k != 0 && k != points.count - 1 { m.ticks.append(p) }
            for (i, bead) in beads(of: id, in: scene).enumerated() {
                let onIt = MotionTiming.same(bead.time, scene.time)
                m.beads.append((bead.at, bead.home, hot == .bead(i) || onIt))
            }
        }
    }
}
