import AppKit

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
    func changePoints(_ action: LocalizedStringResource, _ change: (inout BezierPath) -> Void) {
        guard let (id, points) = editedPoints else { return }
        var next = points
        change(&next)
        setPoints(next, of: id, action)
    }

    /// A path's new points, on the canvas. When none are left, the layer goes.
    func setPoints(_ points: BezierPath, of id: UUID, _ action: LocalizedStringResource) {
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

    // MARK: Combining shapes

    /// The ways overlapping shapes become one path.
    enum Combine: CaseIterable {
        /// All of them, as one outline.
        case union
        /// The shape at the back, less what lies in front of it.
        case subtract
        /// Only where they all overlap.
        case intersect
        /// Only where an odd number of them lie, so where two overlap is cut out.
        case exclude

        var title: LocalizedStringResource {
            switch self {
            case .union: "Union"
            case .subtract: "Subtract"
            case .intersect: "Intersect"
            case .exclude: "Exclude Overlap"
            }
        }
    }

    /// The selected shapes that can be combined, back first: rectangles, ellipses and paths.
    private var combinable: [UUID] {
        selection.filter { id in node(id).map { [.rectangle, .ellipse, .path].contains($0.kind) && !$0.locked } == true }
            .compactMap { id in doc.path(of: id).map { (id, $0.indices) } }
            .sorted { $0.1.lexicographicallyPrecedes($1.1) }
            .map(\.0)
    }

    /// Whether the selection is two or more shapes and nothing else.
    var canCombine: Bool {
        selection.count >= 2 && combinable.count == selection.count
    }

    /// Makes the selected shapes one path, styled as the one at the back and lying where the
    /// frontmost was. When nothing would be left of them, nothing changes.
    func combine(_ how: Combine) {
        guard canCombine else { return }
        let ids = combinable
        let outlines = ids.compactMap { doc.outline(of: $0) }
        guard outlines.count == ids.count, let back = node(ids[0]), let front = doc.path(of: ids[ids.count - 1]) else { return }
        let rest = outlines.dropFirst()
        let combined = switch how {
        case .union: rest.reduce(outlines[0]) { $0.union($1) }
        case .subtract: rest.reduce(outlines[0]) { $0.subtracting($1) }
        case .intersect: rest.reduce(outlines[0]) { $0.intersection($1) }
        case .exclude: rest.reduce(outlines[0]) { $0.symmetricDifference($1) }
        }
        let shape = Outlines.cleaned(combined)
        let o = doc.parentOrigin(of: back.id)
        guard !shape.isEmpty, var made = back.reshaped(to: shape, origin: o) else { NSSound.beep(); return }
        made.id = UUID()
        made.frame = made.frame.offsetBy(dx: o.x, dy: o.y)

        edit(how.title) { doc in
            // Just above the frontmost, which then goes with the rest: what lay over it still does.
            doc.attach(made, to: front.parent.map { doc[$0].id }, at: front.indices[front.indices.count - 1] + 1)
            for id in ids { _ = doc.detach(id) }
        }
        selection = [made.id]
    }
}

nonisolated extension BezzleDocument {
    /// The area a shape's fill covers, on the canvas, with no part of the outline crossing another.
    func outline(of id: UUID) -> CGPath? {
        guard let n = node(id), let p = n.kind == .path ? n : n.asPath(), let data = p.path else { return nil }
        let o = parentOrigin(of: id)
        var t = p.pathPlacement.concatenating(CGAffineTransform(translationX: o.x, y: o.y))
        return PathData.cgPath(data).copy(using: &t)?.normalized(using: n.evenOdd == true ? .evenOdd : .winding)
    }
}

extension BezzleDocument {
    /// A layer's outline on the canvas as it is drawn, open runs and all: what its border follows.
    func line(of id: UUID) -> CGPath? {
        guard let n = node(id) else { return nil }
        let o = parentOrigin(of: id)
        var t = CGAffineTransform(translationX: o.x, y: o.y)
        let placed = Renderer.placedOutline(of: n)
        return placed.copy(using: &t)
    }
}

nonisolated extension Node {
    /// The same layer as a path whose outline is `outline` on the canvas, its parent starting at
    /// `origin` there; its frame is in the parent, as any layer's. It keeps its turn and its look,
    /// and a gradient stays where it lay.
    func reshaped(to outline: CGPath, origin o: CGPoint) -> Node? {
        guard var made = kind == .path ? self : asPath() else { return nil }
        // In the layer's own upright coordinates, so the path keeps its turn.
        var toFrame = placement.concatenating(CGAffineTransform(translationX: o.x, y: o.y)).inverted()
        guard let upright = outline.copy(using: &toFrame) else { return nil }
        let box = upright.boundingBoxOfPath
        guard !box.isNull, box.width.isFinite, box.height.isFinite else { return nil }
        made.frame = CGRect(center: CGPoint(x: box.midX, y: box.midY).applying(placement), size: box.size)
        made.path = PathData.string(upright)
        made.pathBox = box
        // What comes out of Core Graphics never crosses itself, and its holes wind the other way.
        made.evenOdd = nil
        made.fill.gradient = fill.gradient?.moved(from: frame.size, to: box)
        return made
    }
}
