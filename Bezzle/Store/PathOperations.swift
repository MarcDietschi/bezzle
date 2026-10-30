import Foundation

/// What can be done to a path's points: from the canvas, as they are dragged and clicked, and
/// from the inspector.
extension DocumentStore {
    /// The path whose points are being edited, and its points on the canvas.
    var editedPoints: (id: UUID, points: BezierPath)? {
        guard let id = editingPath, let points = points(of: id) else { return nil }
        return (id, points)
    }

    /// A path's points on the canvas, read once for each version of the design.
    func points(of id: UUID) -> BezierPath? {
        if pointsWorkedOut.version != version { pointsWorkedOut = (version, [:]) }
        if let points = pointsWorkedOut.points[id] { return points }
        guard let points = doc.points(of: id) else { return nil }
        pointsWorkedOut.points[id] = points
        return points
    }

    /// The picked points that are still there, after an undo has taken some away.
    var livePoints: Set<PathPoint> {
        guard let (_, points) = editedPoints else { return [] }
        return selectedPoints.filter { points.contains($0) }
    }

    /// Starts editing the points of the one selected path.
    func editPoints() {
        guard selection.count == 1, let n = node(selection[0]), n.kind == .path, !n.locked else { return }
        if tool != .pen { tool = .select }
        editingPath = n.id
    }

    /// Changes the edited path's points as one step of the undo history.
    func changePoints(_ action: String, _ change: (inout BezierPath) -> Void) {
        guard let (id, points) = editedPoints else { return }
        var next = points
        change(&next)
        setPoints(next, of: id, action)
    }

    /// A path's new points, on the canvas. When none are left, the layer goes.
    func setPoints(_ points: BezierPath, of id: UUID, _ action: String) {
        edit(action) { $0.setPoints(points, of: id) }
        if node(id) == nil {
            selection.removeAll { $0 == id }
        } else {
            // What will be asked for next is what was just given, less the handles path data can't
            // keep: the pen holds those itself, and drops them when its newest point is clicked.
            pointsWorkedOut = (version, [id: points.stored])
        }
    }

    func selectAllPoints() {
        guard let (_, points) = editedPoints else { return }
        selectedPoints = Set(points.allPoints)
    }

    /// Takes the picked points away, joining those either side.
    func deleteSelectedPoints() {
        let picked = livePoints
        guard !picked.isEmpty else { return }
        changePoints(picked.count == 1 ? "Delete Point" : "Delete Points") { $0.remove(picked) }
        selectedPoints = []
    }

    func nudgePoints(dx: CGFloat, dy: CGFloat) {
        let picked = livePoints
        guard !picked.isEmpty else { return }
        changePoints("Move Points") { p in
            for q in picked { p[q] = p[q].offset(by: CGPoint(x: dx, y: dy)) }
        }
    }

    /// Whether the picked points are smooth, sharp corners, or some of each (nil).
    var pickedSmooth: Bool? {
        guard let (_, points) = editedPoints else { return nil }
        let kinds = Set(livePoints.map { points.isSmooth($0) })
        return kinds.count == 1 ? kinds.first : nil
    }

    func setSmooth(_ smooth: Bool, _ picked: Set<PathPoint>? = nil) {
        let picked = picked ?? livePoints
        guard !picked.isEmpty else { return }
        changePoints(smooth ? "Smooth Points" : "Sharpen Points") { p in
            for q in picked { if smooth { p.makeSmooth(q) } else { p.makeCorner(q) } }
        }
    }

    /// Where the picked points are, measured in the path's artboard: one value when they share it.
    func pickedPosition(x: Bool) -> Double? {
        guard let (id, points) = editedPoints else { return nil }
        let o = doc.parentOrigin(of: id)
        let values = Set(livePoints.map { q -> Double in
            let p = points[q].point
            return ((x ? p.x - o.x : p.y - o.y) * 100).rounded() / 100
        })
        return values.count == 1 ? values.first : nil
    }

    /// Moves each picked point so that `f` of where it is, measured in the artboard, is where it goes.
    func movePicked(x: Bool, _ f: (Double) -> Double) {
        guard let (id, _) = editedPoints else { return }
        let o = doc.parentOrigin(of: id), picked = livePoints
        changePoints("Move Points") { p in
            for q in picked {
                let at = p[q].point
                let now = Double(x ? at.x - o.x : at.y - o.y)
                let to = CGFloat(f(now))
                let d = x ? CGPoint(x: to + o.x - at.x, y: 0) : CGPoint(x: 0, y: to + o.y - at.y)
                p[q] = p[q].offset(by: d)
            }
        }
    }

    // MARK: Whole paths

    /// Whether the selected paths come back round to where they began: nil when some do and some do not.
    var selectedPathsClosed: Bool? {
        let runs = selection.compactMap { points(of: $0) }.flatMap(\.subpaths).map(\.closed)
        let kinds = Set(runs)
        return kinds.count == 1 ? kinds.first : nil
    }

    /// Closes each selected path with a line from its last point to its first, or opens it there.
    func setClosed(_ closed: Bool) {
        let ids = selection.filter { node($0)?.kind == .path && node($0)?.locked == false }
        guard !ids.isEmpty else { return }
        edit(closed ? "Close Path" : "Open Path") { doc in
            for id in ids {
                guard var points = doc.points(of: id) else { continue }
                for s in points.subpaths.indices { points.subpaths[s].closed = closed }
                doc.setPoints(points, of: id)
            }
        }
    }

    /// Rectangles, ellipses and lines in the selection become paths, so their points can be edited.
    var canConvertToPath: Bool {
        selectedNodes.contains { !$0.locked && $0.asPath() != nil }
    }

    func convertToPath() {
        let ids = selection.filter { node($0)?.locked == false && node($0)?.asPath() != nil }
        guard !ids.isEmpty else { return }
        update(ids, "Convert to Path") { n in
            if let path = n.asPath() { n = path }
        }
    }
}
