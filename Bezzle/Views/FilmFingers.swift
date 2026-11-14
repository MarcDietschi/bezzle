import SwiftUI
import AppKit

/// Two fingers on the film's timeline, and the wheel over it: told to the hand (`FilmHand`),
/// which does the looking closer and the moving along.
///
/// - A pinch looks closer or from further off, about the moment under the pointer.
/// - A double tap with two fingers goes back to the whole film, or from it, closer.
/// - Two fingers sideways, or the wheel with Shift, move a sheet looked at closer along. Up and
///   down they are left to the lines, which scroll as before.
/// - The wheel with Command, Option or Control held looks closer or from further off, as it
///   zooms the canvas.
///
/// SwiftUI tells a view of none of these where the pointer is, so they are caught on their way
/// into the window and taken when they are over the sheet (`FilmGround`).
final class FilmFingers {
    let hand: FilmHand
    /// The sheet: the names and the lines beside them, under the ruler.
    weak var ground: NSView?
    var menus: MenuHost?
    private var monitor: Any?
    /// Whether the pinch going on began over the sheet, and so is the timeline's to its end.
    private var pinching = false
    /// Whose the scrolling going on is, settled by its first move and kept until the fingers
    /// are put down again: the timeline's, or not (the lines', or the canvas's).
    private var scrolling: Bool?
    /// Where the pointer was over the sheet when the fingers were last told of.
    private var place: (x: CGFloat, width: CGFloat)?

    init(hand: FilmHand) {
        self.hand = hand
    }

    func watch() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .magnify, .smartMagnify]) { [weak self] event in
            self?.take(event) == true ? nil : event
        }
    }

    func rest() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        pinching = false
        scrolling = nil
    }

    /// Where an event is over the sheet: how far along the lines, from where their moments
    /// begin, and how wide they are. Nil off the sheet, in another window, or under a menu.
    private func spot(of event: NSEvent) -> (x: CGFloat, width: CGFloat)? {
        guard let ground, let window = ground.window, menus?.open == nil else { return nil }
        var inWindow = event.locationInWindow
        if let other = event.window {
            guard other === window else { return nil }
        } else {
            // An event of no window says where it is on the screen.
            inWindow = window.convertPoint(fromScreen: inWindow)
        }
        let p = ground.convert(inWindow, from: nil)
        guard ground.bounds.contains(p) else { return nil }
        let width = ground.bounds.width
        return (p.x - ground.bounds.minX - FilmTimeline.names(in: width), FilmTimeline.sheet(in: width))
    }

    /// Takes an event that is the timeline's. False for any other, which goes on its way.
    func take(_ event: NSEvent) -> Bool {
        switch event.type {
        case .magnify:
            if event.phase.contains(.began) {
                place = spot(of: event)
                pinching = place != nil
            } else if event.phase.isEmpty, !pinching {
                // Told of without its beginning: the timeline's where the pointer is on it.
                place = spot(of: event)
                guard let at = place else { return false }
                hand.zoom(by: 1 + Double(event.magnification), at: at.x, scale: hand.scale(width: at.width))
                hand.pointAgain(width: at.width)
                return true
            }
            guard pinching, let at = place else { return false }
            if event.magnification != 0 { hand.zoom(by: 1 + Double(event.magnification), at: at.x, scale: hand.scale(width: at.width)) }
            if event.phase.contains(.ended) || event.phase.contains(.cancelled) {
                pinching = false
                hand.pointAgain(width: at.width)
            }
            return true
        case .smartMagnify:
            guard let at = spot(of: event) else { return false }
            hand.smartZoom(at: at.x, scale: hand.scale(width: at.width))
            hand.pointAgain(width: at.width)
            return true
        case .scrollWheel:
            return scroll(event)
        default:
            return false
        }
    }

    private func scroll(_ event: NSEvent) -> Bool {
        let fingers = !event.phase.isEmpty || !event.momentumPhase.isEmpty
        // Fingers put down anew: whose their scrolling is, is settled anew.
        if event.phase.contains(.began) || event.phase.contains(.mayBegin) { scrolling = nil }
        let flags = event.modifierFlags
        let zooming = flags.contains(.command) || flags.contains(.option) || flags.contains(.control)
        var dx = event.scrollingDeltaX, dy = event.scrollingDeltaY
        if !event.hasPreciseScrollingDeltas { dx *= 8; dy *= 8 }
        // Shift turns the wheel sideways, as on the canvas; mostly the system has done so already.
        if flags.contains(.shift), dx == 0 { dx = dy; dy = 0 }
        var ours = fingers ? scrolling : nil
        if ours == nil {
            guard dx != 0 || dy != 0 else { return false }
            place = spot(of: event)
            // The wheel with a key held looks closer anywhere on the sheet; sideways moves a
            // sheet along that is looked at closer. Up and down is the lines'.
            ours = place != nil && (zooming || (abs(dx) > abs(dy) && hand.zoomed))
            if fingers { scrolling = ours }
        }
        guard ours == true, let at = place else { return false }
        let scale = hand.scale(width: at.width)
        if zooming {
            let step = event.hasPreciseScrollingDeltas ? 0.012 : 0.1
            if event.scrollingDeltaY != 0 { hand.zoom(by: exp(Double(event.scrollingDeltaY) * step), at: at.x, scale: scale) }
        } else if dx != 0 {
            hand.scroll(by: dx, scale: scale)
        }
        // Once the sheet rests, what the pointer is on is found again; the wheel has no end to
        // wait for, and turns slowly enough to find it at every step.
        if !fingers || event.phase.contains(.ended) || event.phase.contains(.cancelled) || event.momentumPhase.contains(.ended) {
            hand.pointAgain(width: at.width)
        }
        return true
    }
}

/// The sheet's own place in the window, for `FilmFingers` to tell whether the pointer is on it.
/// It takes no clicks: everything on the sheet is SwiftUI's.
struct FilmGround: NSViewRepresentable {
    let fingers: FilmFingers

    func makeNSView(context: Context) -> NSView {
        let view = Ground()
        fingers.ground = view
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        fingers.ground = view
    }

    private final class Ground: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
