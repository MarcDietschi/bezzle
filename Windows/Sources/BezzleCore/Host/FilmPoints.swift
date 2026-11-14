import Foundation

// Animate: a shape's points moved at the playhead, and added and taken away there, as the Mac's
// FilmPoints (Canvas/FilmPoints.swift, ported). The shared pen (`PenTool`) does it as it does in
// the design, with this for its host: the points are where the film shows them at the playhead,
// through the layer's pose and the camera (`Node.filmPointMap`), and every change is a pose of
// the layer's Shape there, as moving a layer is a pose of where it is. The design's outline is
// never changed here: an outline with other points than it has is one the key holds itself
// (`Node.poseShape`).
//
// The canvas hand (`MotionHand`) owns it, takes the points in hand and hands the pen the pointer
// and the keys while they are.

extension WindowsCore {
    @MainActor final class FilmPoints: PenHost {
        private let desk: FilmDesk
        /// The film on the desk and the pieces it is made of: the canvas hand's.
        private let film: () -> (board: Node, pieces: [FilmPiece])?
        /// Where the canvas is on the stage: a canvas point `p` is at `pan + p · zoom`.
        private let view: () -> (zoom: CGFloat, pan: CGPoint)
        /// Points moved in a way no pose can keep, or taken away so that nothing is left to draw:
        /// the canvas beeps.
        var beep: () -> Void = {}

        init(desk: FilmDesk, view: @escaping () -> (zoom: CGFloat, pan: CGPoint), film: @escaping () -> (board: Node, pieces: [FilmPiece])?) {
            self.desk = desk
            self.view = view
            self.film = film
        }

        /// The shape whose points are in hand. The panel and the canvas follow it.
        var editingPath: UUID? {
            didSet {
                guard editingPath != oldValue else { return }
                selectedPoints = []
                guides = []
                desk.changed()
            }
        }
        var selectedPoints: Set<PathPoint> = []
        var guides: [Guide] = []

        var doc: BezzleDocument { WindowsCore.design ?? BezzleDocument() }
        var seenDoc: BezzleDocument { doc }
        var selection: [UUID] {
            get { desk.selection }
            set { desk.select(newValue) }
        }
        var livePoints: Set<PathPoint> {
            guard let (_, points) = editedPoints else { return [] }
            return selectedPoints.filter { points.contains($0) }
        }
        var editedPoints: (id: UUID, points: BezierPath)? {
            guard let id = editingPath, let points = points(of: id) else { return nil }
            return (id, points)
        }
        var penInHand: Bool { false }
        var selecting: Bool { true }
        func dropPen() {}
        var zoom: CGFloat { view().zoom }
        func toView(_ p: CGPoint) -> CGPoint {
            let (zoom, pan) = view()
            return CGPoint(x: pan.x + p.x * zoom, y: pan.y + p.y * zoom)
        }
        func toCanvas(_ v: CGPoint) -> CGPoint {
            let (zoom, pan) = view()
            return CGPoint(x: (v.x - pan.x) / zoom, y: (v.y - pan.y) / zoom)
        }
        func node(_ id: UUID) -> Node? { WindowsCore.design?.node(id) }
        func add(_ node: Node, onto artboard: UUID?, action: LocalizedStringResource?) {}

        func beginGesture() { WindowsCore.beginGesture() }
        /// A drag of points ends as one step. The pen ends a press that moved nothing too, which
        /// began no gesture and changes nothing.
        func endGesture(_ action: LocalizedStringResource) {
            guides = []
            guard WindowsCore.inGesture else { return }
            WindowsCore.endGesture()
            desk.edited()
        }
        func cancelGesture() {
            guides = []
            guard WindowsCore.inGesture else { return }
            WindowsCore.cancelGesture()
            desk.edited()
        }

        /// Where the film shows a layer's own points at the playhead, and where its artboard lies
        /// on the canvas.
        private func placing(_ id: UUID) -> (map: FilmMap, origin: CGPoint, node: Node)? {
            guard let (board, pieces) = film(), let node = board.descendant(id), node.canReshape,
                  let map = board.filmPointMap(of: id, at: desk.filmTime, pieces: pieces) else { return nil }
            return (map, board.frame.origin, node)
        }

        /// A shape's points on the canvas, where the film shows them at the playhead.
        func points(of id: UUID) -> BezierPath? {
            guard let (map, origin, node) = placing(id), let outline = node.outline(at: desk.filmTime) else { return nil }
            return outline.mapped { p in
                let q = map(p)
                return CGPoint(x: q.x + origin.x, y: q.y + origin.y)
            }
        }

        /// Points moved, added or taken away on the canvas: the layer's Shape posed at the playhead
        /// to have them there, with the design's points, each moved, or as an outline the key
        /// holds itself (`Node.poseShape`). An outline with nothing left to draw is no pose, and
        /// changes nothing. Inside a drag each pose is made again from where the drag began, as
        /// every change of a gesture is here: a point added by a press and dragged on is one step.
        func setPoints(_ points: BezierPath, of id: UUID, _ action: LocalizedStringResource) {
            guard let (map, origin, node) = placing(id), !node.locked else { return }
            guard let own = points.mapped({ map.back(CGPoint(x: $0.x - origin.x, y: $0.y - origin.y)) }),
                  node.shapeValue(of: own) != nil else {
                beep()
                return
            }
            desk.poseShape(of: id, own)
        }

        private func changePoints(_ change: (inout BezierPath) -> Void) {
            guard let (id, points) = editedPoints else { return }
            var next = points
            change(&next)
            setPoints(next, of: id, "Move Points")
        }

        func setSmooth(_ smooth: Bool, _ picked: Set<PathPoint>?) {
            let picked = picked ?? livePoints
            guard !picked.isEmpty else { return }
            changePoints { p in
                for q in picked { if smooth { p.makeSmooth(q) } else { p.makeCorner(q) } }
            }
        }

        /// Takes the picked points away at the playhead, joining those either side: the outline
        /// that leaves is what the key there holds. The last of a shape's points stay.
        func deleteSelectedPoints() {
            let picked = livePoints
            guard !picked.isEmpty, let (id, points) = editedPoints else { return }
            var next = points
            next.remove(picked)
            guard FilmPointRules.leavesAnOutline(runs: next.subpaths.map(\.anchors.count)) else {
                beep()
                return
            }
            setPoints(next, of: id, picked.count == 1 ? "Delete Point" : "Delete Points")
            selectedPoints = []
        }

        func nudgePoints(dx: CGFloat, dy: CGFloat) {
            let picked = livePoints
            guard !picked.isEmpty else { return }
            changePoints { p in
                for q in picked { p[q] = p[q].offset(by: CGPoint(x: dx, y: dy)) }
            }
        }

        /// Takes the points of the one picked shape in hand.
        func editPoints() {
            guard selection.count == 1, let n = film()?.board.descendant(selection[0]), n.canReshape, !n.locked else { return }
            editingPath = n.id
        }
    }
}

extension WindowsCore.FilmDesk {
    /// Whether the Pose card shows Draw and Shape: every layer picked is a shape whose outline is
    /// points (a path, rectangle, ellipse or line).
    public var posedShapes: Bool {
        guard let board = filmBoard else { return false }
        return FilmPointRules.showsShape(posedLayers.map { board.descendant($0)?.canReshape == true })
    }

    /// Poses a layer's Shape at the playhead so its outline is `outline` there, in its own upright
    /// points: what moving its points on the canvas does, and adding them and taking them away.
    func poseShape(of id: UUID, _ outline: BezierPath) {
        let t = filmTime
        let before = WindowsCore.design
        WindowsCore.edit { doc in doc.update(id) { $0.poseShape(outline, at: t) } }
        if WindowsCore.design != before { edited() }
    }

    // MARK: Another shape's outline (the Mac's AnimateOperations)

    /// The Pose card's chip that gives a shape another's outline, in the Mac's words for it,
    /// which its catalog keeps under a name of their own.
    public static var shapeFromTitle: String { String(localized: "animate.shape.from", defaultValue: "From…") }

    /// The shapes whose outline a shape can take at the playhead: the others on the film's
    /// artboard, the one in front first (`Node.shapesToTake`), each by its id and its name. None
    /// for a layer that is locked, or has no outline itself.
    public func shapesToTake(for id: UUID) -> [(id: UUID, name: String)] {
        guard let board = filmBoard else { return [] }
        return board.shapesToTake(for: id).map { ($0.id, $0.name) }
    }

    /// Gives a shape the outline another has at the playhead, about its own middle: a key of its
    /// Shape there, which it then goes into and comes from as from any other. One step. False,
    /// with nothing changed, when the other has no outline to give there or this one cannot take
    /// it: the panel beeps.
    @discardableResult
    public func takeShape(of other: UUID, for id: UUID) -> Bool {
        guard let board = filmBoard, let layer = board.descendant(id), !layer.locked else { return false }
        let t = filmTime
        guard let outline = board.outline(of: other, for: id, at: t), layer.shapeValue(of: outline) != nil else { return false }
        let before = WindowsCore.design
        WindowsCore.edit { doc in doc.update(id) { $0.poseShape(taking: outline, at: t) } }
        if WindowsCore.design != before { edited() }
        return true
    }
}
