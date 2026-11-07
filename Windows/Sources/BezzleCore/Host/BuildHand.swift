import Foundation

// Building with the pieces overlapping shapes cut each other into, on the Windows canvas: the
// shared PieceBuilding (Model/ShapeBuilding.swift), as the Mac's canvas uses it, its host the
// open design. The Arrange card's Build button and Ctrl+Alt+B start and end it.

extension WindowsCore {
    @MainActor public final class BuildHand: BuildHost {
        /// The shapes being built with, or nil while nothing is.
        public var building: [UUID]? {
            didSet { if building != oldValue { changed?() } }
        }
        /// Building started or done.
        public var changed: (() -> Void)?
        /// Pieces joined or wiped away: the shapes now picked.
        public var built: (([UUID]) -> Void)?
        /// Where the canvas is on screen: a canvas point `p` is at `pan + p · zoom`.
        public var zoom: CGFloat = 1
        public var pan: CGPoint = .zero
        private lazy var tool = PieceBuilding(host: self)
        /// The pieces, worked out once for the shapes as they are.
        private var worked: (ids: [UUID], nodes: [Node], origins: [CGPoint], pieces: [Outlines.Piece])?

        public init() {}

        public var redraw: () -> Void {
            get { tool.redraw }
            set { tool.redraw = newValue }
        }

        /// Starts building with the shapes picked, when they can be made one; whether it started.
        @discardableResult public func start(_ ids: [UUID]) -> Bool {
            guard let doc = WindowsCore.design, doc.canCombine(ids) else { return false }
            building = doc.backFirst(ids)
            return true
        }

        public var active: Bool { building != nil }

        // MARK: The host

        private var doc: BezzleDocument { WindowsCore.design ?? BezzleDocument() }
        /// The shapes being built with that are still there, back first.
        private var shapes: [UUID] { doc.backFirst((building ?? []).filter { doc.node($0) != nil }) }

        var buildPieces: [Outlines.Piece] {
            let doc = doc, ids = shapes
            let nodes = ids.compactMap { doc.node($0) }, origins = ids.map { doc.parentOrigin(of: $0) }
            if let w = worked, w.ids == ids, w.nodes == nodes, w.origins == origins { return w.pieces }
            let pieces = doc.buildPieces(of: ids)
            worked = (ids, nodes, origins, pieces)
            return pieces
        }

        func build(_ picked: [Int], erase: Bool) {
            let ids = shapes
            guard let plan = doc.buildPlan(picked, erase: erase, shapes: ids, pieces: buildPieces) else { return }
            var now: [UUID] = []
            WindowsCore.edit { now = $0.build(plan, shapes: ids) }
            building = now.isEmpty ? nil : now
            built?(now)
        }

        func toView(_ p: CGPoint) -> CGPoint { CGPoint(x: pan.x + p.x * zoom, y: pan.y + p.y * zoom) }
        func toCanvas(_ v: CGPoint) -> CGPoint { CGPoint(x: (v.x - pan.x) / zoom, y: (v.y - pan.y) / zoom) }

        // MARK: For the canvas

        public var dragging: Bool { tool.dragging }

        /// A press at `v` on the stage while building: on a piece it starts joining (wiping with
        /// Alt); anywhere else building is done, and false leaves the press to the canvas.
        public func down(at v: CGPoint, option: Bool) -> Bool { tool.down(at: v, option: option) }
        public func drag(to v: CGPoint, option: Bool) { tool.drag(to: v, option: option) }
        public func up(at v: CGPoint) { tool.up(at: v) }
        @discardableResult public func hover(_ v: CGPoint?, option: Bool) -> Bool { tool.hover(v, option: option) }
        /// Enter or Escape: a drag let go of, or building done; whether the key was taken.
        public func key(_ key: String) -> Bool { tool.key(key == "escape" ? .escape : key == "enter" ? .enter : .other) }

        /// What the pointer shows while building: the cross for pieces, marked to wipe them away,
        /// over a piece; nil while nothing is built with.
        public var pointer: (onPiece: Bool, erase: Bool)? { tool.pointer }

        /// What shows, on the stage: each piece's outline as path data, lit under the pointer or
        /// touched by the drag (tinted, solid) or not (faint, dashed); the drag's way; and whether
        /// it wipes away (red) or joins (blue).
        public struct Marks {
            public let pieces: [(data: String, lit: Bool)]
            public let trail: [CGPoint]
            public let erasing: Bool
        }
        public func marks() -> Marks {
            let m = tool.marks()
            var t = CGAffineTransform(a: zoom, b: 0, c: 0, d: zoom, tx: pan.x, ty: pan.y)
            return Marks(pieces: m.pieces.map { (PathData.string($0.outline.copy(using: &t) ?? $0.outline), $0.lit) }, trail: m.trail, erasing: m.erasing)
        }
    }

    /// The Build button's picture, 28 square, as the Mac's CombineButton draws it: two overlapping
    /// squares, their overlap to shade, their outlines, and a stroke across all three, as the drag
    /// that joins them goes.
    public static func buildGlyph() -> (shade: String, outlines: [String], swipe: String) {
        let side: CGFloat = 9, step: CGFloat = 5
        let x = ((28 - side - step) / 2).rounded(), y = ((28 - side - step) / 2).rounded()
        let back = CGPath(roundedRect: CGRect(x: x, y: y, width: side, height: side), cornerWidth: 1.5, cornerHeight: 1.5, transform: nil)
        let front = CGPath(roundedRect: CGRect(x: x + step, y: y + step, width: side, height: side), cornerWidth: 1.5, cornerHeight: 1.5, transform: nil)
        let swipe = CGMutablePath()
        swipe.move(to: CGPoint(x: x + 2.5, y: y + 3.5))
        swipe.addQuadCurve(to: CGPoint(x: x + step + side - 2.5, y: y + step + side - 3.5), control: CGPoint(x: x + 9.5, y: y + 4.5))
        return (PathData.string(back.intersection(front)), [back, front].map(PathData.string), PathData.string(swipe))
    }
}
