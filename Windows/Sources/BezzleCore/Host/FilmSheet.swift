import Foundation

// Animate: the timeline's sheet looked at closer, as the Mac's FilmRuler, FilmThumb, FilmHand and
// FilmFingers decide it (Views/FilmTimeline.swift, FilmHand.swift, FilmFingers.swift): which
// strokes the ruler draws and what their numbers say, the stroke under the lines that shows which
// part of the film is in sight, what a turn of the wheel does, and how fast the sheet creeps
// under a hand past either end of what shows. Where a moment lies, and how far the sheet can be
// looked at and moved, is the shared FilmScale and FilmWindow (Model/FilmKeys.swift), tested on
// the Mac (BezzleTests/FilmZoomTests.swift). Numbers in and numbers out: nothing here asks
// Windows or the design anything, so Windows/Tests checks it on a Mac too.

nonisolated public enum FilmSheet {
    // MARK: The ruler

    /// The seconds between numbered strokes, and how many parts each is ruled in, so the numbers
    /// stand clear of each other: fewer of them as the film is looked at from further off, and
    /// more, down to twentieths of a second, as it is looked at closer. The strokes between come
    /// down to hundredths, a key's finest step, once those are wide enough to tell apart.
    public static func step(_ perSecond: Double) -> (major: Double, parts: Int) {
        let steps: [(Double, Int)] = [(0.05, 5), (0.1, 2), (0.2, 4), (0.5, 5), (1, 10), (2, 4), (5, 5), (10, 10), (20, 4), (30, 6), (60, 6), (120, 4), (300, 5)]
        let (major, parts) = steps.first { $0.0 * perSecond >= 52 } ?? (600, 10)
        // Tenths are halved into twentieths, where a key steps; closer still, into hundredths.
        if major == 0.1, perSecond >= 600 { return (major, 10) }
        return (major, parts)
    }

    /// The strokes a ruler `width` points wide draws, a second `perSecond` points wide on it and
    /// the film's start at `origin`: the first stroke's number, counted in parts from the film's
    /// start, and one past the last. Only those in sight, with the numbered one before them
    /// whose number may still reach in, however long the film and however close.
    public static func strokes(perSecond: Double, origin: Double, width: Double) -> (first: Int, end: Int, major: Double, parts: Int) {
        let (major, parts) = step(perSecond)
        let part = major / Double(parts) * perSecond
        guard part > 0, part.isFinite, origin.isFinite, width.isFinite else { return (0, 0, major, parts) }
        var first = Int(min(max((-origin / part).rounded(.down), 0), 1e15))
        first = first / parts * parts
        // None on the last two points, where its number would have no room.
        let end = max(Int(min(max(((width - 2 - origin) / part).rounded(.down), -1), 1e15)) + 1, first)
        return (first, end, major, parts)
    }

    /// A stroke's number: seconds, and from a minute on, minutes and seconds; with the parts of
    /// a second where the strokes are closer than a second apart.
    public static func label(_ t: Double, step: Double = 1) -> String {
        guard t >= 60 else {
            var s = String(format: "%.2f", max(t, 0))
            while s.hasSuffix("0") { s.removeLast() }
            if s.hasSuffix(".") { s.removeLast() }
            return s
        }
        guard step < 1 else {
            let s = Int(t.rounded())
            return String(format: "%d:%02d", s / 60, s % 60)
        }
        let hundredths = Int((t * 100).rounded())
        let rest = hundredths % 6000
        var out = String(format: "%d:%02d", hundredths / 6000, rest / 100)
        if rest % 100 != 0 { out += rest % 10 == 0 ? ".\(rest % 100 / 10)" : String(format: ".%02d", rest % 100) }
        return out
    }

    // MARK: Which part shows

    /// The stroke under the lines of a sheet looked at closer: where it begins and how long it
    /// is, as long against the sheet as the part shown (`span` seconds from `start`) is against
    /// the film's whole sheet of `whole` seconds, eighteen points at least, and as far along as
    /// that part is in the film. `inset` is the room either side of the sheet's moments.
    public static func thumb(width: Double, inset: Double, start: Double, span: Double, whole: Double) -> (x: Double, long: Double) {
        let room = max(width - inset * 2, 1)
        let long = max(room * min(span / max(whole, 1e-9), 1), 18)
        let along = whole > span ? start / (whole - span) : 0
        return (inset + (room - long) * min(max(along, 0), 1), long)
    }

    // MARK: The wheel

    /// How many times closer a turn of the wheel looks, with Ctrl held or as two fingers pinch:
    /// what the same turn does to the canvas (`DesignCanvas.wheel`).
    public static func closer(byWheel delta: Double) -> Double { pow(1.0015, delta) }

    /// How many points a turn of the wheel moves the sheet along, sideways or with Shift held,
    /// counted the way the moments go: as the same turn moves the canvas, whose design goes left
    /// as the wheel is turned to the right.
    public static func along(byWheel delta: Double) -> Double { -delta }

    // MARK: Past the ends of a sheet looked at closer

    /// How fast the sheet moves along under a pointer that drags something past the first or the
    /// last moment it shows, in points a second: slowly just past it, faster the further out,
    /// to the left under nought and to the right over it. Nothing within the sheet.
    public static func creepRate(at x: Double, width: Double, inset: Double) -> Double {
        let near = inset, far = width - inset
        let past = x < near ? x - near : x > far ? x - far : 0
        guard past != 0 else { return 0 }
        return (past < 0 ? -1 : 1) * min(40 + abs(past) * 12, 1600)
    }
}
