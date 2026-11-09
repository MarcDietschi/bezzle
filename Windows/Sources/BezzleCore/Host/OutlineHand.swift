import Foundation

// A selected shape's outline on the Windows canvas: its corners' dots, and its edge pulled out or
// in with Alt. The shared OutlineDragging (Model/OutlineDragging.swift), as the Mac's canvas uses
// it, its host the open design.

extension WindowsCore {
    @MainActor public final class OutlineHand: OutlineHost {
        /// What is picked; a copy pulled out of an outline is picked when let go (`picked`).
        public var selection: [UUID] = [] {
            didSet { if selection != oldValue, !following { picked?(selection) } }
        }
        public var picked: (([UUID]) -> Void)?
        private var following = false

        /// Takes in what the window has picked, without saying it back as this hand's picking:
        /// that picked it all again, and made every panel again inside the drawing of the outline.
        public func follow(_ ids: [UUID]) {
            following = true
            selection = ids
            following = false
        }
        /// Whether the select tool is in hand with nothing being typed or edited.
        public var free = true
        /// Where the canvas is on screen: a canvas point `p` is at `pan + p · zoom`.
        public var zoom: CGFloat = 1
        public var pan: CGPoint = .zero
        private lazy var tool = OutlineDragging(host: self)

        public init() {}

        public var redraw: () -> Void {
            get { tool.redraw }
            set { tool.redraw = newValue }
        }

        // MARK: The host

        var doc: BezzleDocument { WindowsCore.design ?? BezzleDocument() }
        var selectsFreely: Bool { free }
        func toView(_ p: CGPoint) -> CGPoint { CGPoint(x: pan.x + p.x * zoom, y: pan.y + p.y * zoom) }
        func toCanvas(_ v: CGPoint) -> CGPoint { CGPoint(x: (v.x - pan.x) / zoom, y: (v.y - pan.y) / zoom) }
        func points(of id: UUID) -> BezierPath? { doc.points(of: id) }
        func setPoints(_ points: BezierPath, of id: UUID, _ action: LocalizedStringResource) { WindowsCore.edit { $0.setPoints(points, of: id) } }
        func beginGesture() { WindowsCore.beginGesture() }
        func endGesture(_ action: LocalizedStringResource) { WindowsCore.endGesture() }
        func cancelGesture() { WindowsCore.cancelGesture() }
        func edit(_ action: LocalizedStringResource, _ change: (inout BezzleDocument) -> Void) { WindowsCore.edit(change) }

        private static func number(_ v: Double) -> String {
            let r = (v * 10).rounded() / 10 + 0
            return r == r.rounded() ? String(Int(r)) : String(format: "%.1f", r)
        }

        func measure(_ what: OutlineMeasure?, _ box: CGRect) {
            switch what {
            case nil: WindowsCore.measure = nil
            case .radius(let r)?: WindowsCore.measure = (WindowsCore.say("Radius %@", Self.number(Double(r))), box)
            case .outset(let d)?: WindowsCore.measure = (WindowsCore.say("Outset %@", Self.number(Double(d))), box)
            case .inset(let d)?: WindowsCore.measure = (WindowsCore.say("Inset %@", Self.number(Double(d))), box)
            }
        }

        // MARK: For the canvas

        private func flags(_ shift: Bool, _ option: Bool) -> PenFlags {
            var f: PenFlags = []
            if shift { f.insert(.shift) }
            if option { f.insert(.option) }
            return f
        }

        public var dragging: Bool { tool.dragging }

        /// A press at `v` on the stage on a corner's dot, or on the edge with Alt; false leaves it
        /// to the canvas.
        public func down(at v: CGPoint, shift: Bool, option: Bool) -> Bool { tool.down(at: v, flags: flags(shift, option)) }
        public func drag(to v: CGPoint, shift: Bool, option: Bool) { tool.drag(to: v, flags: flags(shift, option)) }
        public func up() { tool.up() }
        public func cancel() { tool.cancel() }
        @discardableResult public func hover(_ v: CGPoint?, shift: Bool, option: Bool) -> Bool { tool.hover(v, flags: flags(shift, option)) }

        /// What the pointer shows: a cross on a corner's dot, or an arrow across the edge, at an
        /// angle in degrees.
        public enum Pointer { case cross, across(Double) }
        public func pointer(at v: CGPoint) -> Pointer? {
            switch tool.pointer(at: v) {
            case .cross?: .cross
            case .across(let a)?: .across(a)
            case nil: nil
            }
        }

        /// What shows, on the stage: the edge lit with Alt over it (path data, 2 points of the
        /// canvas's blue), and the corner dots (7 points, white with a blue ring).
        public func marks() -> (edge: String?, dots: [CGPoint]) {
            let m = tool.marks()
            return (m.edge.map { PathData.string($0) }, m.dots)
        }
    }
}
