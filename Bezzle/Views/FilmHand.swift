import SwiftUI
import AppKit

// MARK: - The hand

/// The pointer on the film's timeline: what it is on, and what a press has in hand. Kept apart
/// from the views, which only tell it where the pointer is and what is held down, so that it can
/// be driven without them.
@Observable
final class FilmHand {
    @ObservationIgnored let store: DocumentStore
    var hot = Hot()
    var drag: Drag?
    /// The seconds the card shows, held as they were while something is dragged.
    var held: Double?
    /// Where the press last was, and on how wide a sheet: what a drag goes on from when the
    /// sheet moves under a pointer that holds still.
    @ObservationIgnored private var last: (p: CGPoint, dx: CGFloat, width: CGFloat, flags: NSEvent.ModifierFlags)?
    @ObservationIgnored private var creeper: Timer?
    @ObservationIgnored private var crept: CFTimeInterval = 0

    init(store: DocumentStore) {
        self.store = store
    }

    /// How near the pointer takes a bead, and how near a moment catches the playhead, in points.
    static let reach: CGFloat = 7

    /// What the pointer is on.
    struct Hot: Equatable {
        var key: FilmKeyRef?
        /// The line whose band it is on.
        var band: String?
        var row: String?
        var x: CGFloat = 0
        /// On the flag at the film's end.
        var end = false
        /// On the ruler, rather than on the lines under it.
        var ruler = false
    }

    /// What a press has in hand.
    struct Drag: Equatable {
        enum Kind { case scrub, keys, band, length, nothing }
        var kind: Kind
        /// The keys as they were when taken.
        var refs: [FilmKeyRef] = []
        /// The moment of the one under the pointer, which is what catches on others.
        var anchor = 0.0
        /// The moment the pointer was at when it took them: they keep their distance from it,
        /// however the sheet is moved along or looked at meanwhile.
        var grip = 0.0
        var moved = false
        var caught: Double?
    }

    func picked(_ row: FilmRow) -> Bool {
        row.camera ? store.film.camera : store.selection.contains(row.layer)
    }

    // MARK: The sheet

    /// Whether the card shows a part of the film, looked at closer, rather than all of it.
    var zoomed: Bool { store.film.window?.fitted(to: store.filmWhole) != nil }

    /// Where moments lie along a sheet this wide, as the card shows it now: the part of the
    /// film looked at; or the whole film, held as it was while something is dragged.
    func scale(width: CGFloat) -> FilmScale {
        var scale = store.filmScale(width: width)
        if let held, !zoomed { scale.span = held }
        return scale
    }

    // MARK: Pointing

    /// What is under a point of the sheet: a bead within reach, else the band of the line there.
    func point(_ p: CGPoint, rows: [FilmRow], scale: FilmScale) -> Hot {
        var out = Hot(x: p.x)
        let i = Int((p.y / FilmTimeline.rowHeight).rounded(.down))
        guard rows.indices.contains(i) else { return out }
        let row = rows[i]
        out.row = row.id
        let near = row.marks.min { abs(scale.x($0.t) - p.x) < abs(scale.x($1.t) - p.x) }
        if let near, abs(scale.x(near.t) - p.x) <= Self.reach {
            out.key = FilmKeyRef(row.layer, row.property, input: row.input, at: near.t)
        } else if let first = row.marks.first, let last = row.marks.last, last.t > first.t, p.x > scale.x(first.t), p.x < scale.x(last.t) {
            out.band = row.id
        }
        return out
    }

    func pointRuler(_ p: CGPoint, scale: FilmScale, length: Double) -> Hot {
        Hot(x: p.x, end: abs(p.x - scale.x(length)) <= 8, ruler: true)
    }

    /// What the pointer is on, found again where it rests: after the sheet has moved under it.
    func pointAgain(width: CGFloat) {
        guard drag == nil, let board = store.filmBoard else { return }
        let scale = scale(width: width)
        var now = hot
        if hot.ruler {
            now = pointRuler(CGPoint(x: hot.x, y: 0), scale: scale, length: board.filmLength)
        } else if let id = hot.row {
            let rows = FilmRow.rows(of: board, open: store.film.open)
            guard let i = rows.firstIndex(where: { $0.id == id }) else { return }
            now = point(CGPoint(x: hot.x, y: (CGFloat(i) + 0.5) * FilmTimeline.rowHeight), rows: rows, scale: scale)
        }
        if now != hot { hot = now }
    }

    /// Picks what a line is of: its layer, or the camera.
    private func pick(_ row: FilmRow, adding: Bool = false) {
        if row.camera {
            if !store.film.camera { store.pickCamera() }
        } else if !store.selection.contains(row.layer) {
            store.selection = adding ? store.selection + [row.layer] : [row.layer]
        }
    }

    // MARK: Pressing and dragging

    /// A press on the sheet. On a bead it picks its key, with Shift one more or one fewer; on a
    /// line's band it takes the whole motion; twice on a line it sets a key there; anywhere else
    /// it takes the playhead.
    func press(at p: CGPoint, rows: [FilmRow], scale: FilmScale, flags: NSEvent.ModifierFlags = [], clicks: Int = 1) {
        let at = point(p, rows: rows, scale: scale)
        hot = at
        let row = rows.first { $0.id == at.row }
        let shift = flags.contains(.shift)
        if let ref = at.key, let row {
            pick(row, adding: shift)
            var keys = Set(store.pickedKeys)
            if shift {
                if keys.contains(ref) { keys.remove(ref) } else { keys.insert(ref) }
            } else if !keys.contains(ref) {
                keys = [ref]
            }
            store.film.keys = keys
            drag = keys.contains(ref) ? Drag(kind: .keys, refs: Array(keys), anchor: ref.time, grip: scale.t(p.x)) : Drag(kind: .nothing)
        } else if let row, clicks >= 2 {
            // Twice on a line holds it there: a key where there was none.
            pick(row)
            store.film.keys = []
            store.seek(snapped(scale.t(p.x)))
            if let property = row.property { store.toggleKey(property) } else if let input = row.input { store.toggleInputKey(input) } else { store.holdHere() }
            drag = Drag(kind: .nothing)
        } else if at.band != nil, let row {
            pick(row)
            let refs = row.marks.map { FilmKeyRef(row.layer, row.property, input: row.input, at: $0.t) }
            store.film.keys = Set(refs)
            drag = Drag(kind: .band, refs: refs, anchor: refs.first?.time ?? 0, grip: scale.t(p.x))
        } else {
            if !store.film.keys.isEmpty { store.film.keys = [] }
            drag = Drag(kind: .scrub)
        }
    }

    /// A press on the ruler: on the flag it takes the film's end, twice lets the film be as long
    /// as its keys again; anywhere else it takes the playhead.
    func pressRuler(at p: CGPoint, scale: FilmScale, length: Double, clicks: Int = 1) {
        hot = pointRuler(p, scale: scale, length: length)
        guard hot.end else {
            drag = Drag(kind: .scrub)
            return
        }
        if clicks >= 2 {
            withAnimation(Theme.spring) { store.setFilm("Film Length") { $0.length = nil } }
            drag = Drag(kind: .nothing)
        } else {
            drag = Drag(kind: .length)
        }
    }

    /// The press moved on: to `p`, `dx` points from where it began. Command lets go of
    /// everything a moment catches on, and Option steps finer.
    func dragged(to p: CGPoint, by dx: CGFloat, rows: [FilmRow], scale: FilmScale, length: Double, flags: NSEvent.ModifierFlags = []) {
        guard var d = drag else { return }
        let free = flags.contains(.command), fine = flags.contains(.option)
        // On a sheet looked at closer, what is dragged past either end of the part shown waits
        // at that end, in sight, while the sheet moves along under it (`creep`).
        let zoomed = zoomed
        last = (p, dx, scale.width, flags)
        switch d.kind {
        case .nothing:
            break
        case .scrub:
            // The sheet is moved along by this hand alone, not to wherever the playhead lands.
            store.seek(moment(p.x, scale, rows, free: free, fine: fine, caught: &d.caught, length: length), following: false)
        case .keys, .band:
            if !d.moved {
                guard abs(dx) >= 3 else { break }
                d.moved = true
                held = scale.span
                store.beginGesture()
            }
            // As far from where they were as the pointer is from the moment it took them at.
            var at = scale.t(p.x)
            if zoomed { at = min(max(at, scale.start), scale.start + scale.span) }
            var to = d.anchor + at - d.grip
            if !free {
                // The one in hand catches on the others' moments and on the playhead; between them
                // it steps by twentieths of a second, with Option by hundredths.
                let taken = Set(d.refs.map(\.ms))
                var stops = [store.filmTime]
                for row in rows { for m in row.marks where !taken.contains(FilmKeyRef(row.layer, at: m.t).ms) { stops.append(m.t) } }
                let near = stops.min { abs($0 - to) < abs($1 - to) }
                if let near, abs(near - to) * Double(scale.perSecond) <= Double(Self.reach) - 1 {
                    if d.caught != near { NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now) }
                    d.caught = near
                    to = near
                } else {
                    d.caught = nil
                    let grid = fine ? 0.01 : 0.05
                    to = (to / grid).rounded() * grid
                }
            }
            store.film.keys = Set(store.retime(d.refs, by: to - d.anchor))
        case .length:
            if !d.moved {
                guard abs(dx) >= 2 else { break }
                d.moved = true
                held = scale.span
                store.beginGesture()
            }
            var t = scale.t(p.x)
            let last = store.filmBoard?.lastKey ?? 0
            if !free {
                // It catches where the last key is; else by quarters of a second.
                if last > 0, abs(last - t) * Double(scale.perSecond) <= Double(Self.reach) {
                    if d.caught != last { NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now) }
                    d.caught = last
                    t = last
                } else {
                    d.caught = nil
                    let grid = fine ? 0.05 : 0.25
                    t = (t / grid).rounded() * grid
                }
            }
            t = min(max(t, 0.25), scale.start + scale.span)
            store.setFilm("Film Length") { $0.length = MotionTiming.time(t) }
        }
        // Only when it changed: the timeline is drawn again each time it is set.
        if drag != d { drag = d }
        creepIfNeeded()
    }

    /// The press let go.
    func ended(scale: FilmScale, flags: NSEvent.ModifierFlags = []) {
        guard let d = drag else { return }
        drag = nil
        last = nil
        creepIfNeeded()
        switch d.kind {
        case .keys:
            // A bead only clicked is where the playhead goes.
            if d.moved { store.endGesture("Move Key") } else if !flags.contains(.shift) { store.seek(d.anchor) }
        case .band:
            // A line's band taken and let go is only a place to put the playhead; moved, it has
            // moved the whole motion. Either way its keys are let go of again.
            if d.moved { store.endGesture("Move Key") } else { store.seek(snapped(scale.t(hot.x))) }
            store.film.keys = []
        case .length:
            if d.moved { store.endGesture("Film Length") }
        case .scrub, .nothing:
            break
        }
        withAnimation(Theme.spring) { held = nil }
    }

    /// The drag gone on from where the pointer rests, after the sheet has moved under it.
    private func again() {
        guard drag != nil, let last, let board = store.filmBoard else { return }
        dragged(to: last.p, by: last.dx, rows: FilmRow.rows(of: board, open: store.film.open), scale: scale(width: last.width),
                length: board.filmLength, flags: last.flags)
    }

    // MARK: Past the ends of a sheet looked at closer

    /// How fast the sheet moves along under a pointer that drags something past the first or the
    /// last moment it shows, in points a second: slowly just past it, faster the further out.
    /// Nothing within the sheet.
    static func creepRate(at x: CGFloat, width: CGFloat) -> CGFloat {
        let near = FilmScale.inset, far = width - FilmScale.inset
        let past = x < near ? x - near : x > far ? x - far : 0
        guard past != 0 else { return 0 }
        return (past < 0 ? -1 : 1) * min(40 + abs(past) * 12, 1600)
    }

    /// Moves a sheet looked at closer along under what is dragged past either end of the part
    /// it shows, as far as it goes in `seconds`, and has the drag go on from there: the playhead,
    /// the keys or the film's end stay at that end of the sheet, and the film runs by under
    /// them. False where nothing moved: nothing in hand, the whole film showing, the pointer
    /// within the sheet, or the film's own end reached.
    @discardableResult
    func creep(_ seconds: Double) -> Bool {
        guard let d = drag, d.kind != .nothing, let last, zoomed else { return false }
        let rate = Self.creepRate(at: last.p.x, width: last.width)
        guard rate != 0 else { return false }
        let before = scale(width: last.width)
        let to = before.scrolled(by: -rate * CGFloat(seconds), whole: store.filmWhole)
        guard to != before else { return false }
        store.lookAtFilm(to)
        again()
        return true
    }

    /// Keeps the sheet creeping while it has reason to, a step with every frame.
    private func creepIfNeeded() {
        let wanted = drag != nil && drag?.kind != .nothing && zoomed && last.map { Self.creepRate(at: $0.p.x, width: $0.width) != 0 } == true
        if !wanted {
            creeper?.invalidate()
            creeper = nil
        } else if creeper == nil {
            crept = CACurrentMediaTime()
            let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    let now = CACurrentMediaTime()
                    self.creep(min(now - self.crept, 0.1))
                    self.crept = now
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            creeper = timer
        }
    }

    // MARK: Two fingers, and the wheel

    /// The sheet looked at closer, or from further off, about the moment at `x`: a pinch, or the
    /// wheel turned with Command, Option or Control held as on the canvas. It follows the fingers
    /// with nothing gliding; `gliding`, it settles there. Back out as far as the whole film it
    /// catches there, and the trackpad ticks.
    func zoom(by factor: Double, at x: CGFloat, scale: FilmScale, gliding: Bool = false) {
        let whole = store.filmWhole
        let to = scale.zoomed(by: factor, at: x, whole: whole)
        let caught = zoomed && to.window(of: whole) == nil
        look(at: to, gliding: gliding)
        if caught { NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now) }
    }

    /// The sheet moved along by so many points, as two fingers move it, or the wheel: only while
    /// it is looked at closer, as the whole film has nowhere to go.
    func scroll(by dx: CGFloat, scale: FilmScale) {
        look(at: scale.scrolled(by: dx, whole: store.filmWhole), gliding: false)
    }

    /// A double tap with two fingers: back out to the whole film; or, from the whole film,
    /// four times closer where the pointer is.
    func smartZoom(at x: CGFloat, scale: FilmScale) {
        let whole = store.filmWhole
        if zoomed {
            look(at: FilmScale(width: scale.width, span: whole), gliding: true)
        } else {
            look(at: scale.zoomed(by: 4, at: x, whole: whole), gliding: true)
        }
    }

    /// Has the card show what a scale shows, at once or gliding there.
    private func look(at scale: FilmScale, gliding: Bool) {
        let whole = store.filmWhole
        guard scale.window(of: whole) != store.film.window?.fitted(to: whole) else { return }
        if gliding {
            withAnimation(Theme.spring) { store.lookAtFilm(scale) }
        } else {
            // Under the fingers, nothing springs: the sheet is where they put it.
            var now = Transaction()
            now.disablesAnimations = true
            withTransaction(now) { store.lookAtFilm(scale) }
        }
        // What was under the pointer has moved away from it: found again once the fingers rest
        // (`pointAgain`), as finding it takes every line.
        if hot.key != nil || hot.band != nil || hot.end { hot = Hot(row: hot.row, x: hot.x, ruler: hot.ruler) }
        again()
    }

    private func snapped(_ t: Double) -> Double { max((t / 0.05).rounded() * 0.05, 0) }

    /// The moment under the pointer for the playhead: a key's when one is within reach, else
    /// the nearest twentieth of a second.
    private func moment(_ x: CGFloat, _ scale: FilmScale, _ rows: [FilmRow], free: Bool, fine: Bool, caught: inout Double?, length: Double) -> Double {
        // Within the film, and within what of it the sheet shows.
        let t = min(max(scale.t(x), max(scale.start, 0)), min(length, scale.start + scale.span))
        guard !free else { return t }
        var stops = [0, length]
        for row in rows { stops.append(contentsOf: row.marks.map(\.t)) }
        if let near = stops.min(by: { abs($0 - t) < abs($1 - t) }), abs(near - t) * Double(scale.perSecond) <= Double(Self.reach) - 1 {
            if caught != near, near > 0, near < length { NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now) }
            caught = near
            return near
        }
        caught = nil
        let grid = fine ? 0.01 : 0.05
        return (t / grid).rounded() * grid
    }

    // MARK: The menu

    /// What a right click offers on what the pointer is on: on a bead, how its key is come to
    /// and its removal; elsewhere on a line, a key there and the removal of the whole motion.
    func menu(rows: [FilmRow], scale: FilmScale) -> [MenuEntry] {
        guard let row = rows.first(where: { $0.id == hot.row }) else { return [] }
        let store = store
        pick(row)
        var entries: [MenuEntry] = []
        if let ref = hot.key {
            if !store.film.keys.contains(ref) { store.film.keys = [ref] }
            let shared = store.sharedEase?.kind
            for kind in MotionEase.Kind.allCases {
                entries.append(.item(.verbatim(MotionEase(kind: kind).title), checked: shared == kind) {
                    store.setEase(kind == .spring ? .spring() : MotionEase(kind: kind))
                })
            }
            entries.append(.separator)
            entries.append(.item("Remove Key", shortcut: "⌫") { store.removeFilmKeys() })
        } else {
            let t = snapped(scale.t(hot.x))
            let property = row.property, input = row.input
            store.film.keys = []
            entries.append(.item("Add Key Here") {
                store.seek(t)
                if let property { store.toggleKey(property) } else if let input { store.toggleInputKey(input) } else { store.holdHere() }
            })
            entries.append(.separator)
            entries.append(.item(row.camera ? "Remove the Camera's Motion" : "Remove Motion") { store.clearFilmMotion() })
        }
        return entries
    }
}
