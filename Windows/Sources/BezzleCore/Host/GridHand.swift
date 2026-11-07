import Foundation

// A selected repeat grid on the Windows canvas: the shared GridHandles (Model/GridHandles.swift),
// as the Mac's canvas uses it, its host the open design. The canvas hands it the pointer while
// the select tool is in hand, and draws what it says shows.

extension WindowsCore {
    @MainActor public final class GridHand: GridHost {
        public var selection: [UUID] = []
        /// Whether the select tool is in hand with nothing being typed or edited.
        public var free = true
        /// Where the canvas is on screen: a canvas point `p` is at `pan + p · zoom`.
        public var zoom: CGFloat = 1
        public var pan: CGPoint = .zero
        private lazy var tool = GridHandles(host: self)

        public init() {}

        /// Draws the canvas's marks again.
        public var redraw: () -> Void {
            get { tool.redraw }
            set { tool.redraw = newValue }
        }

        // MARK: The host

        var doc: BezzleDocument { WindowsCore.design ?? BezzleDocument() }
        var selectsFreely: Bool { free }
        func toView(_ p: CGPoint) -> CGPoint { CGPoint(x: pan.x + p.x * zoom, y: pan.y + p.y * zoom) }
        func toCanvas(_ v: CGPoint) -> CGPoint { CGPoint(x: (v.x - pan.x) / zoom, y: (v.y - pan.y) / zoom) }
        func beginGesture() { WindowsCore.beginGesture() }
        func endGesture(_ action: LocalizedStringResource) { WindowsCore.endGesture() }
        func cancelGesture() { WindowsCore.cancelGesture() }
        func edit(_ action: LocalizedStringResource, _ change: (inout BezzleDocument) -> Void) { WindowsCore.edit(change) }

        private static func number(_ v: Double) -> String {
            let r = (v * 10).rounded() / 10 + 0
            return r == r.rounded() ? String(Int(r)) : String(format: "%.1f", r)
        }

        func measure(_ what: GridMeasure?, _ box: CGRect) {
            switch what {
            case nil:
                WindowsCore.measure = nil
            case .cells(let columns, let rows)?:
                let cells = columns * rows
                WindowsCore.measure = (cells > 1 ? "\(columns) × \(rows)  ·  \(cells) cells" : "\(columns) × \(rows)", box)
            case .gap(let gap, let both)?:
                WindowsCore.measure = ((both ? "Gaps " : "Gap ") + Self.number(Double(gap)), box)
            case .angle(let angle)?:
                WindowsCore.measure = ("\(Self.number(angle))°", box)
            }
        }

        // MARK: For the canvas

        public var dragging: Bool { tool.dragging }

        /// A press at `v` on the stage on a selected grid's handle, gap or corner; false leaves it
        /// to the canvas.
        public func down(at v: CGPoint) -> Bool { tool.down(at: v) }
        public func drag(to v: CGPoint, shift: Bool) { tool.drag(to: v, flags: shift ? .shift : []) }
        public func up() { tool.up() }
        public func cancel() { tool.cancel() }
        /// The pointer at rest, or gone (nil); whether what it lights changed.
        @discardableResult public func hover(_ v: CGPoint?) -> Bool { tool.hover(v) }

        /// A grid's outline on the stage, round its cells the way its rows run.
        public func outline(of id: UUID) -> [CGPoint]? { tool.outline(of: id) }

        /// What the pointer shows: pulling or spacing the way an angle runs, or turning from a
        /// corner whose way from the middle is an angle, in degrees clockwise.
        public enum Pointer { case resize(Double), turn(Double) }
        public func pointer(at v: CGPoint) -> Pointer? {
            switch tool.pointer(at: v) {
            case .resize(let a)?: .resize(a)
            case .turn(let a)?: .turn(a)
            case nil: nil
            }
        }

        /// What shows, on the stage, drawn in this order: the same layer in the other cells
        /// (dashed), each cell (faintly dashed, less faintly while cells are pulled out), the gaps
        /// lit (a band with its two edges), the cells to come (clearer the nearer, 0…1), and the
        /// handles: pulls along the right and bottom edges (with two grip lines across) and a dot
        /// at the corner, each drawn upright about its middle and turned by its angle in degrees.
        public struct Marks {
            public let copies: [[CGPoint]]
            public let cells: [[CGPoint]]
            public let cellsActive: Bool
            public let gaps: [(corners: [CGPoint], edges: [(CGPoint, CGPoint)])]
            public let ghosts: [(corners: [CGPoint], near: Double)]
            public let handles: [(at: CGPoint, angle: Double, size: CGSize, dot: Bool, across: Bool)]
        }
        public func marks() -> Marks {
            let m = tool.marks()
            return Marks(copies: m.copies, cells: m.cells, cellsActive: m.cellsActive,
                         gaps: m.gaps.map { ($0.corners, $0.edges) },
                         ghosts: m.ghosts.map { ($0.corners, Double($0.near)) },
                         handles: m.handles.map { ($0.at, $0.angle, $0.size, $0.part == .both, $0.part == .columns) })
        }
    }
}
