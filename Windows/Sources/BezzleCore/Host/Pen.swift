import Foundation

// The pen and a path's points on Windows: the shared PenTool (Model/PenTool.swift), as the Mac's
// canvas uses it, its host the open design. The canvas hands it the pointer and the keys while
// the pen is in hand or a path's points are being edited, and draws what it says shows.

extension WindowsCore {
    @MainActor public final class Pen: PenHost {
        public var selection: [UUID] = []
        public var editingPath: UUID? {
            didSet { if editingPath != oldValue { selectedPoints = [] } }
        }
        var selectedPoints: Set<PathPoint> = []
        var guides: [Guide] = []
        public var penInHand = false
        public var selecting = true
        /// What putting the pen down does: the canvas takes the select tool again.
        public var onDropPen: (() -> Void)?
        /// Where the canvas is on screen: a canvas point `p` is at `pan + p · zoom`.
        public var zoom: CGFloat = 1
        public var pan: CGPoint = .zero
        private lazy var tool = PenTool(host: self)

        public init() {}

        /// Draws the canvas's marks again, for what changes here and not in the design.
        public var redraw: () -> Void {
            get { tool.redraw }
            set { tool.redraw = newValue }
        }

        // MARK: The host

        var doc: BezzleDocument { WindowsCore.design ?? BezzleDocument() }
        var seenDoc: BezzleDocument { doc }
        var editedPoints: (id: UUID, points: BezierPath)? {
            guard let id = editingPath, let points = points(of: id) else { return nil }
            return (id, points)
        }
        var livePoints: Set<PathPoint> {
            guard let (_, points) = editedPoints else { return [] }
            return selectedPoints.filter { points.contains($0) }
        }
        func dropPen() {
            penInHand = false
            selecting = true
            onDropPen?()
        }
        func toView(_ p: CGPoint) -> CGPoint { CGPoint(x: pan.x + p.x * zoom, y: pan.y + p.y * zoom) }
        func toCanvas(_ v: CGPoint) -> CGPoint { CGPoint(x: (v.x - pan.x) / zoom, y: (v.y - pan.y) / zoom) }
        func node(_ id: UUID) -> Node? { WindowsCore.design?.node(id) }
        func points(of id: UUID) -> BezierPath? { WindowsCore.design?.points(of: id) }

        /// A change: inside a gesture added to what the gesture has done so far (the pen adds a
        /// layer and then shapes it in one drag), else one step of the history.
        private func change(_ f: (inout BezzleDocument) -> Void) {
            guard let doc = WindowsCore.design else { return }
            if let start = Editing.gestureStart {
                WindowsCore.design = Editing.edited(doc, start: start, f)
            } else {
                WindowsCore.edit(f)
            }
        }

        func setPoints(_ points: BezierPath, of id: UUID, _ action: LocalizedStringResource) {
            change { $0.setPoints(points, of: id) }
            if node(id) == nil { selection.removeAll { $0 == id } }
        }

        func add(_ node: Node, onto artboard: UUID?, action: LocalizedStringResource?) {
            change { $0.attach(node, to: node.isArtboard ? nil : artboard) }
            selection = [node.id]
        }

        func beginGesture() { WindowsCore.beginGesture() }
        func endGesture(_ action: LocalizedStringResource) {
            WindowsCore.endGesture()
            guides = []
        }
        func cancelGesture() {
            if let start = Editing.gestureStart {
                WindowsCore.design = start
                Editing.gestureStart = nil
            }
            guides = []
        }

        private func changePoints(_ f: (inout BezierPath) -> Void) {
            guard let (id, points) = editedPoints else { return }
            var next = points
            f(&next)
            setPoints(next, of: id, "Move Points")
        }

        func setSmooth(_ smooth: Bool, _ picked: Set<PathPoint>?) {
            let picked = picked ?? livePoints
            guard !picked.isEmpty else { return }
            changePoints { p in for q in picked { if smooth { p.makeSmooth(q) } else { p.makeCorner(q) } } }
        }

        func deleteSelectedPoints() {
            let picked = livePoints
            guard !picked.isEmpty else { return }
            changePoints { $0.remove(picked) }
            selectedPoints = []
        }

        func nudgePoints(dx: CGFloat, dy: CGFloat) {
            let picked = livePoints
            guard !picked.isEmpty else { return }
            changePoints { p in for q in picked { p[q] = p[q].offset(by: CGPoint(x: dx, y: dy)) } }
        }

        func editPoints() {
            guard selection.count == 1, let n = node(selection[0]), n.kind == .path, !n.locked else { return }
            if !penInHand { selecting = true }
            editingPath = n.id
        }

        // MARK: For the canvas

        /// Starts editing the points of the one selected path.
        public func editSelectedPoints() { editPoints() }

        private func flags(_ shift: Bool, _ option: Bool, _ command: Bool) -> PenFlags {
            var f: PenFlags = []
            if shift { f.insert(.shift) }
            if option { f.insert(.option) }
            if command { f.insert(.command) }
            return f
        }

        /// Whether a press, drag or the keys are the pen's now.
        public var dragging: Bool { tool.dragging }
        /// The path whose points show in place of its frame.
        public var shownPath: UUID? { tool.shownPath }
        /// What a click where the pointer is would do, for its look: none, point, add, remove,
        /// close, convert or carryOn.
        public var mark: String { "\(tool.mark)" }

        public func penDown(at v: CGPoint, shift: Bool, option: Bool, command: Bool) {
            tool.penDown(at: v, flags: flags(shift, option, command))
        }

        /// A press while a path's points are being edited; false when it is on none of its points,
        /// handles or outline.
        public func editDown(at v: CGPoint, shift: Bool, option: Bool, command: Bool, clicks: Int) -> Bool {
            tool.editDown(at: v, flags: flags(shift, option, command), clicks: clicks)
        }

        public func startMarquee(at v: CGPoint, adding: Bool, offPath: Bool) { tool.startMarquee(at: v, adding: adding, offPath: offPath) }
        public func drag(to v: CGPoint, shift: Bool, option: Bool, command: Bool) { tool.drag(to: v, flags: flags(shift, option, command)) }
        public func up(at v: CGPoint, shift: Bool, option: Bool, command: Bool) { tool.up(at: v, flags: flags(shift, option, command)) }
        public func hover(_ v: CGPoint?, shift: Bool, option: Bool, command: Bool) { tool.hover(v, flags: flags(shift, option, command)) }

        /// The keys the pen takes: escape, enter, delete, left, right, up or down.
        public func key(_ name: String, shift: Bool) -> Bool {
            let key: PenKey = switch name {
            case "escape": .escape
            case "enter": .enter
            case "delete": .delete
            case "left": .left
            case "right": .right
            case "up": .up
            case "down": .down
            default: .other
            }
            return tool.key(key, flags: flags(shift, false, false))
        }

        /// What shows for the pen, on the stage (in view points): the path's outline and the curve
        /// still to come as path data, the handles, the points (filled when picked or newest), the
        /// ring round the first point, the ghost of a point to add, the box dragged round points.
        public struct Overlay {
            public let outline: String?
            public let toCome: String?
            public let handles: [(point: CGPoint, handle: CGPoint)]
            public let anchors: [(point: CGPoint, filled: Bool)]
            public let closing: CGPoint?
            public let spot: CGPoint?
            public let marquee: CGRect?
        }

        public func overlay() -> Overlay {
            let o = tool.overlay()
            let t = CGAffineTransform(a: zoom, b: 0, c: 0, d: zoom, tx: pan.x, ty: pan.y)
            var toCome: String?
            if let c = o.toCome {
                let path = CGMutablePath()
                path.move(to: toView(c.from))
                path.addCurve(to: toView(c.to), control1: toView(c.c1), control2: toView(c.c2))
                toCome = PathData.string(path)
            }
            let marquee = o.marquee.map { r in CGRect(origin: toView(r.origin), size: CGSize(width: r.width * zoom, height: r.height * zoom)) }
            return Overlay(outline: o.outline.map { $0.applying(t).data }, toCome: toCome,
                           handles: o.handles.map { (toView($0.point), toView($0.handle)) },
                           anchors: o.anchors.map { (toView($0.point), $0.filled) },
                           closing: o.closing.map(toView), spot: o.spot.map(toView), marquee: marquee)
        }

        // MARK: The Path card, as the Mac's PathCard

        /// Whether the selected paths are closed: nil when some are and some are not.
        public var closed: Bool? { selectedPathsClosed }
        /// Closes the selected paths, or opens them, as one step.
        public func setClosed(_ closed: Bool) {
            let ids = closablePaths
            guard !ids.isEmpty else { return }
            WindowsCore.edit { $0.setClosed(closed, paths: ids) }
        }
        /// Whether some points of the edited path are picked.
        public var picksPoints: Bool { !livePoints.isEmpty }
        /// Whether the picked points are smooth, corners, or some of each (nil).
        public var smoothPicked: Bool? { pickedSmooth }
        public func setPickedSmooth(_ smooth: Bool) { setSmooth(smooth, nil) }
        /// Where the picked points are, across or down, in the path's artboard; nil where they differ.
        public func picked(x: Bool) -> Double? { pickedPosition(x: x) }
        /// Puts the picked points at `v` across or down.
        public func movePicked(x: Bool, to v: Double) { movePicked(x: x) { _ in v } }
        /// Moves each picked point by `d` across or down.
        public func movePicked(x: Bool, by d: Double) { movePicked(x: x) { $0 + d } }

        /// The lines the point being placed or moved catches on, on the canvas.
        public var guideLines: [GuideLine] { guides.map { GuideLine(from: $0.from, to: $0.to, field: $0.field) } }
    }
}
