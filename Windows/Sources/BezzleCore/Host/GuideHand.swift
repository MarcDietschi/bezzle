import Foundation

// Guides on the Windows canvas: the shared GuideDragging (Model/GuideDragging.swift), as the
// Mac's canvas uses it, its host the open design and the canvas's rulers.

extension WindowsCore {
    @MainActor public final class Guides: GuideHost {
        /// Where the canvas is on screen: a canvas point `p` is at `pan + p · zoom`.
        public var zoom: CGFloat = 1
        public var pan: CGPoint = .zero
        /// How big the canvas is on screen, for what is in sight.
        public var size: CGSize = .zero
        /// Whether the select tool is in hand.
        public var selecting = true
        /// The artboard the rulers measure, by its place among the design's layers.
        public var rulerIndex: Int?
        public static let rulerSize: CGFloat = 20
        private lazy var tool = GuideDragging(host: self)

        public init() {}

        public var redraw: () -> Void {
            get { tool.redraw }
            set { tool.redraw = newValue }
        }
        /// A press on a guide that did not become a drag: a click at a point on screen, with Shift.
        public var click: (CGPoint, Bool) -> Void = { _, _ in }
        /// The rulers' corner clicked: the drawing aids' menu, at a point on screen.
        public var cornerMenu: (CGPoint) -> Void {
            get { tool.cornerMenu }
            set { tool.cornerMenu = newValue }
        }
        /// Where the layer a press at a point on screen would take lies on the canvas, if one does.
        public var under: (CGPoint) -> CGRect? {
            get { tool.under }
            set { tool.under = newValue }
        }

        // MARK: The host

        var doc: BezzleDocument { WindowsCore.design ?? BezzleDocument() }
        func toView(_ p: CGPoint) -> CGPoint { CGPoint(x: pan.x + p.x * zoom, y: pan.y + p.y * zoom) }
        func toCanvas(_ v: CGPoint) -> CGPoint { CGPoint(x: (v.x - pan.x) / zoom, y: (v.y - pan.y) / zoom) }
        var visibleCanvasRect: CGRect {
            let a = toCanvas(.zero)
            return CGRect(x: a.x, y: a.y, width: size.width / zoom, height: size.height / zoom)
        }
        var selectsGuides: Bool { selecting }
        var isReadOnly: Bool { false }
        func seenLayers(of board: Node) -> [Node] { board.seenLayers(fronts: WindowsCore.fronts) }
        func beginGesture() { WindowsCore.beginGesture() }
        func endGesture(_ action: LocalizedStringResource) { WindowsCore.endGesture() }
        func cancelGesture() { WindowsCore.cancelGesture() }
        func edit(_ action: LocalizedStringResource, _ change: (inout BezzleDocument) -> Void) { WindowsCore.edit(change) }
        var guidesShown: Bool {
            get { WindowsCore.showsGuides }
            set { WindowsCore.showsGuides = newValue }
        }
        var gridsShown: Bool { WindowsCore.showsGrids }
        var rulersShown: Bool { WindowsCore.showsRulers }
        var guidesLocked: Bool { WindowsCore.guidesLocked }
        func rulerPart(at v: CGPoint) -> RulerPart? {
            guard WindowsCore.showsRulers else { return nil }
            let t = Self.rulerSize, top = v.y >= 0 && v.y < t, left = v.x >= 0 && v.x < t
            if top && left { return .corner }
            if top { return .top }
            if left { return .left }
            return nil
        }
        var rulerBoard: Node? {
            guard let k = rulerIndex, let doc = WindowsCore.design, doc.nodes.indices.contains(k), doc.nodes[k].isArtboard else { return nil }
            return doc.nodes[k]
        }
        var rulerThickness: CGFloat { WindowsCore.showsRulers ? Self.rulerSize : 0 }

        // MARK: For the canvas

        private func flags(_ shift: Bool, _ option: Bool, _ command: Bool) -> PenFlags {
            var f: PenFlags = []
            if shift { f.insert(.shift) }
            if option { f.insert(.option) }
            if command { f.insert(.command) }
            return f
        }

        /// What the pointer shows for guides and the rulers, as the Mac's GuideTool has it.
        public enum Pointer { case across, upDown, cross, pointingHand, arrow }
        public func pointer(at v: CGPoint) -> Pointer? {
            if let vertical = tool.movingVertical, tool.dragging { return vertical ? .across : .upDown }
            if let vertical = tool.newVertical { return tool.held.first?.leaving == true ? .arrow : vertical ? .across : .upDown }
            if tool.crossing { return .cross }
            if let part = rulerPart(at: v) {
                if part == .corner { return .pointingHand }
                if let vertical = tool.tabVertical(at: v) { return vertical ? .across : .upDown }
                return .arrow
            }
            guard !tool.pressed, selecting, let vertical = tool.hoveredVertical else { return nil }
            return vertical ? .across : .upDown
        }

        public var pressed: Bool { tool.pressed }
        public var dragging: Bool { tool.dragging }

        /// A press at `v` on the stage on a ruler, whatever the tool; false leaves it to the canvas.
        public func rulerDown(at v: CGPoint, clicks: Int, shift: Bool, option: Bool, command: Bool) -> Bool {
            tool.click = { [weak self] v, f in self?.click(v, f.contains(.shift)) }
            return tool.rulerDown(at: v, clicks: clicks, flags: flags(shift, option, command))
        }
        /// A press at `v` on the stage with the select tool on a guide's line, where no layer lies
        /// under it; false leaves it to the canvas.
        public func lineDown(at v: CGPoint, shift: Bool, option: Bool, command: Bool) -> Bool {
            tool.click = { [weak self] v, f in self?.click(v, f.contains(.shift)) }
            return tool.down(at: v, flags: flags(shift, option, command))
        }
        public func drag(to v: CGPoint, shift: Bool, option: Bool, command: Bool) { tool.drag(to: v, flags: flags(shift, option, command)) }
        public func up(at v: CGPoint, shift: Bool, option: Bool, command: Bool) { tool.up(at: v, flags: flags(shift, option, command)) }
        public func cancel() { tool.cancel() }
        /// The pointer at rest; whether what it lights changed.
        @discardableResult public func hover(_ v: CGPoint?) -> Bool { tool.hover(v) }

        /// A guide's line as the canvas draws it, on the canvas, and how it shows.
        public struct Line {
            public let from: CGPoint, to: CGPoint
            public let vertical: Bool
            public let lit: Bool
        }
        /// The guides to draw: all but one dragged off to go, the one under the pointer or being
        /// moved lit.
        public func lines() -> [Line] {
            guard WindowsCore.showsGuides else { return [] }
            let moving = tool.moving
            var out: [Line] = []
            for board in doc.artboards where !board.hidden {
                for (key, g) in board.guides ?? [:] {
                    let ref = GuideDragging.Ref(board: board.id, key: key)
                    if ref == moving, tool.held.first?.leaving == true { continue }
                    let (a, b) = tool.line(of: g, on: board)
                    out.append(Line(from: a, to: b, vertical: g.vertical, lit: ref == tool.hovered || ref == moving))
                }
            }
            return out
        }

        /// A guide being dragged: on an artboard, where (its line on the canvas) and its distances
        /// to the two edges, the one toward the edge it keeps to first; or leaving, a short dashed
        /// line at the pointer, and where the pointer is.
        public struct Held {
            public let from: CGPoint, to: CGPoint
            public let vertical: Bool
            public let leaving: Bool
            public let pointer: CGPoint
            /// Each span from an edge to the guide, on the canvas, its length, and whether it is
            /// the one toward the edge it keeps to.
            public let spans: [(from: CGPoint, to: CGPoint, length: CGFloat, kept: Bool)]
        }

        public func held() -> [Held] {
            tool.held.map { h in
                guard let id = h.board, let board = doc.node(id) else {
                    let p = h.pointer, o = 40 / zoom
                    let a = h.vertical ? CGPoint(x: h.position, y: p.y - o) : CGPoint(x: p.x - o, y: h.position)
                    let b = h.vertical ? CGPoint(x: h.position, y: p.y + o) : CGPoint(x: p.x + o, y: h.position)
                    return Held(from: a, to: b, vertical: h.vertical, leaving: true, pointer: p, spans: [])
                }
                let f = board.frame
                let g = Guideline(vertical: h.vertical, edge: .start, offset: h.position)
                var (a, b) = tool.line(of: g, on: board)
                if h.leaving {
                    if h.vertical { a.x = h.pointer.x; b.x = h.pointer.x } else { a.y = h.pointer.y; b.y = h.pointer.y }
                    return Held(from: a, to: b, vertical: h.vertical, leaving: true, pointer: h.pointer, spans: [])
                }
                let length = h.vertical ? f.width : f.height
                let kept = Guideline.at(h.position, vertical: h.vertical, in: f.size).edge
                let start = h.vertical ? f.minX : f.minY
                let across = h.vertical ? h.pointer.y : h.pointer.x
                func point(_ v: CGFloat) -> CGPoint { h.vertical ? CGPoint(x: v, y: across) : CGPoint(x: across, y: v) }
                let spans = [(start, start + h.position, kept != .end), (start + h.position, start + length, kept != .start)]
                    .filter { $0.1 - $0.0 > 0.5 }
                    .map { (from: point($0.0), to: point($0.1), length: $0.1 - $0.0, kept: $0.2) }
                return Held(from: a, to: b, vertical: h.vertical, leaving: false, pointer: h.pointer, spans: spans)
            }
        }

        /// The tabs on the rulers, on screen: the guides of the artboard they measure, and one dragged in.
        public func tabs() -> [(at: CGFloat, vertical: Bool, lit: Bool)] {
            tool.tabs().map { ($0.at, $0.vertical, $0.lit || ($0.ref != nil && $0.ref == tool.beckoning)) }
        }

        /// Which way the guide under the pointer, being moved or coming out runs, for the pointer's look.
        public var pointerRuns: Bool? { tool.movingVertical ?? tool.newVertical ?? tool.hoveredVertical }

        /// A right click at `v` on the stage on a guide: taking it away, or all its artboard's.
        public func menu(at v: CGPoint) -> (remove: () -> Void, removeAll: (() -> Void)?)? {
            guard let (ref, count) = tool.guideForMenu(at: v) else { return nil }
            return ({ [weak self] in self?.tool.removeGuide(ref) }, count > 1 ? { [weak self] in self?.tool.removeGuides(from: ref.board) } : nil)
        }
    }
}
