import AppKit

/// Animate: a shape's points moved at the playhead. The shared pen (`PenTool`) moves them as it
/// does in the design, with this for its host: the points are where the film shows them at the
/// playhead, through the layer's pose and the camera (`Node.filmPointMap`), and every move is a
/// pose of the layer's Shape there, as moving a layer is a pose of where it is. The design's
/// outline is never changed here, and its points are only moved: they are added and taken away
/// in the design.
@MainActor
final class FilmPoints: PenHost {
    private let store: DocumentStore
    /// The film on the desk and the pieces it is made of: the motion tool's.
    private let film: () -> (board: Node, pieces: [FilmPiece])?

    init(store: DocumentStore, film: @escaping () -> (board: Node, pieces: [FilmPiece])?) {
        self.store = store
        self.film = film
    }

    var doc: BezzleDocument { store.doc }
    var seenDoc: BezzleDocument { store.seenDoc }
    var selection: [UUID] {
        get { store.selection }
        set { store.selection = newValue }
    }
    var editingPath: UUID? {
        get { store.editingPath }
        set { store.editingPath = newValue }
    }
    var selectedPoints: Set<PathPoint> {
        get { store.selectedPoints }
        set { store.selectedPoints = newValue }
    }
    var livePoints: Set<PathPoint> {
        guard let (_, points) = editedPoints else { return [] }
        return store.selectedPoints.filter { points.contains($0) }
    }
    var editedPoints: (id: UUID, points: BezierPath)? {
        guard let id = store.editingPath, let points = points(of: id) else { return nil }
        return (id, points)
    }
    var guides: [Guide] {
        get { store.guides }
        set { store.guides = newValue }
    }
    var penInHand: Bool { false }
    var selecting: Bool { true }
    var pointsFixed: Bool { true }
    func dropPen() {}
    var zoom: CGFloat { store.viewport.zoom }
    func toView(_ p: CGPoint) -> CGPoint { store.viewport.toView(p) }
    func toCanvas(_ v: CGPoint) -> CGPoint { store.viewport.toCanvas(v) }
    func node(_ id: UUID) -> Node? { store.node(id) }
    func add(_ node: Node, onto artboard: UUID?, action: LocalizedStringResource?) {}
    func beginGesture() { store.beginGesture() }
    func endGesture(_ action: LocalizedStringResource) { store.endGesture(action) }
    func cancelGesture() { store.cancelGesture() }

    /// Where the film shows a layer's own points at the playhead, and where its artboard lies on
    /// the canvas.
    private func placing(_ id: UUID) -> (map: FilmMap, origin: CGPoint, node: Node)? {
        guard let (board, pieces) = film(), let node = board.descendant(id), node.canReshape,
              let map = board.filmPointMap(of: id, at: store.filmTime, pieces: pieces) else { return nil }
        return (map, board.frame.origin, node)
    }

    /// A shape's points on the canvas, where the film shows them at the playhead.
    func points(of id: UUID) -> BezierPath? {
        guard let (map, origin, node) = placing(id), let outline = node.outline(at: store.filmTime) else { return nil }
        return outline.mapped { p in
            let q = map(p)
            return CGPoint(x: q.x + origin.x, y: q.y + origin.y)
        }
    }

    /// Points moved on the canvas: the layer's Shape posed at the playhead to have them there.
    /// Points added or taken away are no pose, and change nothing.
    func setPoints(_ points: BezierPath, of id: UUID, _ action: LocalizedStringResource) {
        guard let (map, origin, node) = placing(id), !node.locked else { return }
        guard let own = points.mapped({ map.back(CGPoint(x: $0.x - origin.x, y: $0.y - origin.y)) }),
              node.shapeChange(to: own) != nil else {
            NSSound.beep()
            return
        }
        let t = store.filmTime
        store.edit(action) { doc in doc.update(id) { $0.poseShape(own, at: t) } }
    }

    private func changePoints(_ action: LocalizedStringResource, _ change: (inout BezierPath) -> Void) {
        guard let (id, points) = editedPoints else { return }
        var next = points
        change(&next)
        setPoints(next, of: id, action)
    }

    func setSmooth(_ smooth: Bool, _ picked: Set<PathPoint>?) {
        let picked = picked ?? livePoints
        guard !picked.isEmpty else { return }
        changePoints(smooth ? "Smooth Points" : "Sharpen Points") { p in
            for q in picked { if smooth { p.makeSmooth(q) } else { p.makeCorner(q) } }
        }
    }

    /// Points are taken away in the design.
    func deleteSelectedPoints() { NSSound.beep() }

    func nudgePoints(dx: CGFloat, dy: CGFloat) {
        let picked = livePoints
        guard !picked.isEmpty else { return }
        changePoints("Move Points") { p in
            for q in picked { p[q] = p[q].offset(by: CGPoint(x: dx, y: dy)) }
        }
    }

    /// Starts moving the points of the one picked shape.
    func editPoints() {
        guard store.selection.count == 1, let n = store.node(store.selection[0]), n.canReshape, !n.locked else { return }
        store.editingPath = n.id
    }
}
