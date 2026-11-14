import Foundation

// Animate: where the view goes when the desk turns to a film, so that its artboard lies whole
// above the timeline, as the Mac's frameFilm and FilmTimeline.foot(lines:) decide it
// (Store/AnimateOperations.swift, Views/FilmTimeline.swift). Numbers in and numbers out: nothing
// here asks Windows or the design anything, so Windows/Tests checks it on a Mac too.

nonisolated public enum FilmFraming {
    public static let rowHeight = 24.0
    public static let rulerHeight = 24.0

    /// How many of a film's lines the timeline's card shows at once: four at least, seven at most.
    public static func shown(of lines: Int) -> Int { min(max(lines, 4), 7) }

    /// How much of the canvas's foot the card takes with a film of that many lines, with the room
    /// under it: what the film's artboard is kept clear of.
    public static func foot(lines: Int) -> Double { 44 + rulerHeight + Double(shown(of: lines)) * rowHeight + 6 + 14 }

    /// A view of the canvas: a point of the design lies at its place times `zoom`, plus the pan.
    public struct View: Equatable, Sendable {
        public var zoom, panX, panY: Double
        public init(zoom: Double, panX: Double, panY: Double) {
            self.zoom = zoom
            self.panX = panX
            self.panY = panY
        }
    }

    /// The view in which an artboard (`x`, `y`, `width`, `height` on the canvas) lies whole in
    /// the room above the timeline, `roomWidth` by `roomHeight` points; nil where it does already,
    /// twelve points clear of every side. It draws back no further than it must and looks no
    /// closer than it did, twice life size at most (life size, where it looked from further
    /// off). Along a side on
    /// which the artboard shows whole at that zoom without the view moving, the view stays, so
    /// that what lies beside the artboard stays in sight; out of sight both ways, it comes to the
    /// middle.
    public static func framed(x: Double, y: Double, width: Double, height: Double, from view: View,
                              roomWidth w: Double, roomHeight h: Double) -> View? {
        let zoom = view.zoom
        // What shows now, on the canvas.
        let left = -view.panX / zoom, top = -view.panY / zoom
        let edge = 12 / zoom
        let whole = x >= left + edge && x + width <= left + w / zoom - edge && y >= top + edge && y + height <= top + h / zoom - edge
        guard !whole else { return nil }
        let z = max(0.02, min(max(1, min(zoom, 2)), (w - 80) / max(width, 1), (h - 80) / max(height, 1)))
        var toLeft = x + width / 2 - w / 2 / z, toTop = y + height / 2 - h / 2 / z
        // The view as it would be at that zoom without moving, about its own middle.
        let stillLeft = left + w / 2 / zoom - w / 2 / z, stillTop = top + h / 2 / zoom - h / 2 / z
        let margin = 12 / z
        if x >= stillLeft + margin, x + width <= stillLeft + w / z - margin { toLeft = stillLeft }
        if y >= stillTop + margin, y + height <= stillTop + h / z - margin { toTop = stillTop }
        return View(zoom: z, panX: -toLeft * z, panY: -toTop * z)
    }
}
