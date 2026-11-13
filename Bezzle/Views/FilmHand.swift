import SwiftUI
import AppKit

// MARK: - Lines

/// One line of the timeline: the camera, a layer that moves, or one property of either.
struct FilmRow: Identifiable, Equatable {
    var id: String
    /// The layer whose line it is; the artboard for the camera's.
    var layer: UUID
    var camera = false
    /// One property's keys alone, on a line opened out of its layer's.
    var property: MotionProperty?
    var name: String
    var kind: Node.Kind?
    var marks: [Mark] = []

    /// A moment with a key.
    struct Mark: Equatable {
        var t: Double
        /// As designed there: its bead is hollow.
        var home: Bool
        /// Made by Bezzle to go with a first pose, and not yet touched.
        var given: Bool
        /// How it is come to from the one before, on a property's own line.
        var pace: MotionTrack.Pace?
    }

    /// The camera's line, then one for each layer that moves, the front ones first as the
    /// layers list has them; and under those opened, one for each of their properties.
    static func rows(of board: Node, open: Set<UUID>) -> [FilmRow] {
        var out: [FilmRow] = []
        func add(_ node: Node, camera: Bool) {
            let properties = node.motionProperties.filter { $0.isCamera == camera }
            var row = FilmRow(id: node.id.uuidString + (camera ? ":camera" : ""), layer: node.id, camera: camera,
                              name: camera ? String(localized: "animate.camera", defaultValue: "Camera") : node.name,
                              kind: camera ? nil : node.kind)
            row.marks = marks(of: node, properties)
            out.append(row)
            guard open.contains(node.id) else { return }
            for p in properties {
                var line = FilmRow(id: row.id + ":" + p.rawValue, layer: node.id, camera: camera, property: p, name: p.title)
                line.marks = marks(of: node, [p])
                out.append(line)
            }
        }
        add(board, camera: true)
        func walk(_ nodes: [Node]) {
            for n in nodes.reversed() where !n.hidden {
                if n.isAnimated { add(n, camera: false) }
                walk(n.children)
            }
        }
        walk(board.children)
        return out
    }

    static func marks(of node: Node, _ properties: [MotionProperty]) -> [Mark] {
        var out: [Mark] = []
        for p in properties {
            guard let track = node[track: p] else { continue }
            for (i, key) in track.keys.enumerated() {
                let home = MotionTiming.alike(key.v, p.rest)
                if let j = out.firstIndex(where: { MotionTiming.same($0.t, key.t) }) {
                    out[j].home = out[j].home && home
                    out[j].given = out[j].given && key.given == true
                } else {
                    out.append(Mark(t: key.t, home: home, given: key.given == true,
                                    pace: properties.count == 1 && i > 0 ? track.pace(of: i - 1, rest: p.rest) : nil))
                }
            }
        }
        return out.sorted { $0.t < $1.t }
    }
}

/// Where moments lie along the sheet.
struct FilmScale: Equatable {
    var width: CGFloat
    /// The seconds the width shows.
    var span: Double

    /// Room either side, so a bead at the start or the end is whole.
    static let inset: CGFloat = 14

    /// The film, and a little past its end: room for the flag, and to pose something later.
    static func span(for length: Double) -> Double { max(length / 0.9, 0.5) }

    var perSecond: CGFloat { max(width - Self.inset * 2, 1) / CGFloat(span) }
    func x(_ t: Double) -> CGFloat { Self.inset + CGFloat(t) * perSecond }
    func t(_ x: CGFloat) -> Double { Double((x - Self.inset) / perSecond) }
}

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
    }

    /// What a press has in hand.
    struct Drag {
        enum Kind { case scrub, keys, band, length, nothing }
        var kind: Kind
        /// The keys as they were when taken.
        var refs: [FilmKeyRef] = []
        /// The moment of the one under the pointer, which is what catches on others.
        var anchor = 0.0
        var moved = false
        var caught: Double?
    }

    func picked(_ row: FilmRow) -> Bool {
        row.camera ? store.film.camera : store.selection.contains(row.layer)
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
            out.key = FilmKeyRef(row.layer, row.property, at: near.t)
        } else if let first = row.marks.first, let last = row.marks.last, last.t > first.t, p.x > scale.x(first.t), p.x < scale.x(last.t) {
            out.band = row.id
        }
        return out
    }

    func pointRuler(_ p: CGPoint, scale: FilmScale, length: Double) -> Hot {
        Hot(x: p.x, end: abs(p.x - scale.x(length)) <= 8)
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
            var keys = store.film.keys
            if shift {
                if keys.contains(ref) { keys.remove(ref) } else { keys.insert(ref) }
            } else if !keys.contains(ref) {
                keys = [ref]
            }
            store.film.keys = keys
            drag = keys.contains(ref) ? Drag(kind: .keys, refs: Array(keys), anchor: ref.time) : Drag(kind: .nothing)
        } else if let row, clicks >= 2 {
            // Twice on a line holds it there: a key where there was none.
            pick(row)
            store.film.keys = []
            store.seek(snapped(scale.t(p.x)))
            if let property = row.property { store.toggleKey(property) } else { store.holdHere() }
            drag = Drag(kind: .nothing)
        } else if at.band != nil, let row {
            pick(row)
            let refs = row.marks.map { FilmKeyRef(row.layer, row.property, at: $0.t) }
            store.film.keys = Set(refs)
            drag = Drag(kind: .band, refs: refs, anchor: refs.first?.time ?? 0)
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
        switch d.kind {
        case .nothing:
            break
        case .scrub:
            store.seek(moment(p.x, scale, rows, free: free, fine: fine, caught: &d.caught, length: length))
        case .keys, .band:
            if !d.moved {
                guard abs(dx) >= 3 else { break }
                d.moved = true
                held = scale.span
                store.beginGesture()
            }
            var to = d.anchor + Double(dx / scale.perSecond)
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
            t = min(max(t, 0.25), scale.span)
            store.setFilm("Film Length") { $0.length = MotionTiming.time(t) }
        }
        drag = d
    }

    /// The press let go.
    func ended(scale: FilmScale, flags: NSEvent.ModifierFlags = []) {
        guard let d = drag else { return }
        drag = nil
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

    private func snapped(_ t: Double) -> Double { max((t / 0.05).rounded() * 0.05, 0) }

    /// The moment under the pointer for the playhead: a key's when one is within reach, else
    /// the nearest twentieth of a second.
    private func moment(_ x: CGFloat, _ scale: FilmScale, _ rows: [FilmRow], free: Bool, fine: Bool, caught: inout Double?, length: Double) -> Double {
        let t = min(max(scale.t(x), 0), length)
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
            let property = row.property
            store.film.keys = []
            entries.append(.item("Add Key Here") {
                store.seek(t)
                if let property { store.toggleKey(property) } else { store.holdHere() }
            })
            entries.append(.separator)
            entries.append(.item(row.camera ? "Remove the Camera's Motion" : "Remove Motion") { store.clearFilmMotion() })
        }
        return entries
    }
}
