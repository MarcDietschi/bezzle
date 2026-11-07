import Foundation

// Turning in depth on the Windows canvas: the shared DepthTurning (Model/DepthTurning.swift), as
// the Mac's canvas uses it, its host the open design. The canvas hands it the pointer while the
// select tool is in hand, and draws what it says shows.

extension WindowsCore {
    @MainActor public final class Depth: DepthHost {
        public var selection: [UUID] = []
        /// Whether the select tool is in hand with nothing being typed.
        public var free = true
        /// Where the canvas is on screen: a canvas point `p` is at `pan + p · zoom`.
        public var zoom: CGFloat = 1
        public var pan: CGPoint = .zero
        private lazy var tool = DepthTurning(host: self)

        public init() {}

        /// Draws the canvas's marks again, and what a click picks, as the canvas picks it.
        public var redraw: () -> Void {
            get { tool.redraw }
            set { tool.redraw = newValue }
        }
        public var pick: (CGPoint) -> UUID? {
            get { tool.pick }
            set { tool.pick = newValue }
        }

        // MARK: The host

        var doc: BezzleDocument { WindowsCore.design ?? BezzleDocument() }
        var turnsFreely: Bool { free }
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

        func measure(_ what: DepthMeasure?, _ box: CGRect) {
            switch what {
            case nil: WindowsCore.measure = nil
            case .turning(let n)?: WindowsCore.measure = (WindowsCore.say("Turning %lld layers", n), box)
            case .angles(let x, let y)?: WindowsCore.measure = ("X \(Self.number(x))°  Y \(Self.number(y))°", box)
            case .nearness(let z)?: WindowsCore.measure = ("Z \(Self.number(Double(z)))", box)
            }
        }

        // MARK: For the canvas

        public var dragging: Bool { tool.dragging }
        /// Whether the pointer shows that it turns things.
        public var turnsPointer: Bool { tool.turnsPointer }

        /// A press at `v` on the stage, on a turned layer's knob; false leaves it to the canvas.
        public func down(at v: CGPoint, clicks: Int) -> Bool { tool.down(at: v, clicks: clicks) }
        /// A press just outside the middle of a side of what is picked.
        public func startTurn(at v: CGPoint) { tool.startTurn(at: v) }
        public func drag(to v: CGPoint, shift: Bool, option: Bool) { tool.drag(to: v, shift: shift, option: option) }
        public func up(at v: CGPoint, adding: Bool) { tool.up(at: v, adding: adding) }
        public func cancel() { tool.cancel() }
        public func hover(_ v: CGPoint?) { tool.hover(v) }

        /// What shows, on the stage: the ball being turned, the ring where the face is seen edge
        /// on, and the stalk from the middle to the knob.
        public struct Overlay {
            public let ball: (center: CGPoint, radius: CGFloat)?
            public let ring: CGPoint?
            public let stalk: (center: CGPoint, knob: CGPoint)?
        }
        public func overlay() -> Overlay {
            let o = tool.overlay()
            return Overlay(ball: o.ball, ring: o.ring, stalk: o.stalk)
        }
        public static let reach = Double(DepthTurning.reach)
    }
}
