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

    func setSmooth(_ smooth: Bool, _ picked: Set<PathPoint>? = nil) {
        let picked = picked ?? livePoints
        guard !picked.isEmpty else { return }
        changePoints(smooth ? "Smooth Points" : "Sharpen Points") { p in
            for q in picked { if smooth { p.makeSmooth(q) } else { p.makeCorner(q) } }
        }
    }

    // MARK: Whole paths

    /// Closes each selected path with a line from its last point to its first, or opens it there.
    func setClosed(_ closed: Bool) {
        let ids = closablePaths
        guard !ids.isEmpty else { return }
        edit(closed ? "Close Path" : "Open Path") { $0.setClosed(closed, paths: ids) }
    }

    /// Rectangles, ellipses and lines in the selection become paths, so their points can be
    /// edited, and texts the outlines of their letters.
    var canConvertToPath: Bool {
        selection.contains { id in node(id).map { !$0.locked && $0.asPath() != nil } == true || outlinable(id) }
    }

    /// Whether a text can become the outlines of its letters: one with letters to draw, whose
    /// words are its own alone. Those of a repeat grid's cell, a component's copy or a deck's
    /// post would take every other cell's, copy's or post's words with them.
    private func outlinable(_ id: UUID) -> Bool {
        guard let n = node(id), n.kind == .text, !n.locked, !(n.text ?? "").allSatisfy(\.isWhitespace) else { return false }
        return !doc.inCopy(id) && !doc.ancestors(of: id).contains(where: \.isRepeatGrid) && doc.artboard(of: id)?.isDeck != true
    }

    func convertToPath() {
        let shapes = selection.filter { node($0)?.locked == false && node($0)?.asPath() != nil }
        let texts = selection.filter(outlinable)
        guard !shapes.isEmpty || !texts.isEmpty else { return }
        // Words being typed are the text's before it is outlined.
        if !texts.isEmpty, editingText != nil { canvas?.endEditing() }
        var outlined: [(UUID, Node)] = []
        for id in texts {
            // The shape a mask holds the rest in is one path, whatever colours its letters have.
            let holds = doc.parent(of: id)?.holder?.id == id
            if let made = node(id)?.outlinedText(onePath: holds) { outlined.append((id, made)) }
        }
        // Letters that are pictures, as emoji are, have no outlines to take.
        if outlined.count < texts.count { NSSound.beep() }
        guard !shapes.isEmpty || !outlined.isEmpty else { return }
        edit("Convert to Path") { doc in
            for id in shapes {
                doc.update(id) { n in
                    if let path = n.asPath() { n = path }
                }
            }
            // Not `update`, which keeps where each layer is known: a group holds new layers.
            for (id, made) in outlined {
                if let at = doc.path(of: id) { doc[at] = made }
            }
        }
    }

    // MARK: Combining shapes

    /// The ways overlapping shapes become one path (shared: `ShapeCombine`).
    typealias Combine = ShapeCombine

    /// Whether the selection is two or more shapes and nothing else.
    var canCombine: Bool { doc.canCombine(selection) }

    /// Makes the selected shapes one path, styled as the one at the back and lying where the
    /// frontmost was. When nothing would be left of them, nothing changes.
    func combine(_ how: Combine) {
        guard canCombine, let made = doc.combined(selection, how) else {
            if canCombine { NSSound.beep() }
            return
        }
        edit(how.title) { $0.place(combined: made, replacing: selection) }
        selection = [made.id]
    }
}
