import Foundation

// A layout grid's gutters, margins and baselines dragged on the Windows canvas while its card is
// open: the shared LayoutHandles (Model/LayoutHandles.swift), as the Mac's canvas uses it, its
// host the open design.

extension WindowsCore {
    @MainActor public final class LayoutHand: LayoutHost {
        public var selection: [UUID] = []
        /// Whether the select tool is in hand with nothing being typed or edited.
        public var free = true
        /// Whether the Layout Grid card is open.
        public var cardOpen = false
        /// Where the canvas is on screen: a canvas point `p` is at `pan + p · zoom`.
        public var zoom: CGFloat = 1
        public var pan: CGPoint = .zero
        private lazy var tool = LayoutHandles(host: self)

        public init() {}

        /// Draws the canvas's marks again.
        public var redraw: () -> Void {
            get { tool.redraw }
            set { tool.redraw = newValue }
        }

        // MARK: The host

        var doc: BezzleDocument { WindowsCore.design ?? BezzleDocument() }
        var selectsFreely: Bool { free }
        var layoutCardOpen: Bool { cardOpen }
        var gridsShown: Bool { WindowsCore.showsGrids }
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

        func measure(_ what: LayoutMeasure?, _ box: CGRect) {
            switch what {
            case nil: WindowsCore.measure = nil
            case .gutter(let v)?: WindowsCore.measure = (WindowsCore.say("Gutter %@", Self.number(Double(v))), box)
            case .margin(let v)?: WindowsCore.measure = (WindowsCore.say("Margin %@", Self.number(Double(v))), box)
            case .baseline(let v)?: WindowsCore.measure = (WindowsCore.say("Baseline %@", Self.number(Double(v))), box)
            }
        }

        // MARK: For the canvas

        public var dragging: Bool { tool.dragging }
        /// The artboard whose grid is held, or under the pointer, or nil.
        public var workedOn: UUID? {
            tool.heldBoard ?? (tool.hovered != nil ? tool.editable?.id : nil)
        }
        /// The artboard whose grid the canvas can change: selected alone, with its card open.
        public var editable: UUID? { tool.editable?.id }

        /// A press at `v` on the stage on the editable grid's gutters, margins or baselines; false
        /// leaves it to the canvas.
        public func down(at v: CGPoint) -> Bool { tool.down(at: v) }
        public func drag(to v: CGPoint) { tool.drag(to: v) }
        public func up() { tool.up() }
        public func cancel() { tool.cancel() }
        /// Whether the pointer at `v` shows it moves across (columns) or up and down; nil when no
        /// part of the grid is under it or held.
        public func pointer(at v: CGPoint) -> Bool? { tool.pointer(at: v) }
        /// The pointer at rest, or gone (nil); whether what it lights changed.
        @discardableResult public func hover(_ v: CGPoint?) -> Bool { tool.hover(v) }

        /// The part under the pointer or held, on the canvas: a gutter or a margin band (hatched),
        /// or a baseline (no height; the one held firmly, the first less so).
        public func lit() -> [(rect: CGRect, line: Bool, held: Bool)] {
            tool.lit().map { ($0.rect, $0.line, $0.held) }
        }
    }

    /// How many columns of its artboard's layout grid what is being changed spans exactly, and
    /// which it overlaps (by their place among all its columns), while layout grids show.
    public static func columnSpan(_ ids: [UUID]) -> (lit: Set<Int>, exact: Int?, box: CGRect)? {
        guard showsGrids, let doc = design, let first = ids.first, let board = doc.artboard(of: first), board.id != first,
              let box = doc.selectionFrame(ids), let span = board.columnSpan(of: box) else { return nil }
        return (span.lit, span.exact, box)
    }
}
