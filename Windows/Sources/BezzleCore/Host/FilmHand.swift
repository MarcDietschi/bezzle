import Foundation

// The pointer on the film's timeline, as the Mac's FilmHand (Views/FilmHand.swift, ported): what
// it is on, and what a press has in hand. The timeline's lines and where moments lie along them
// are the shared FilmRow and FilmScale (Model/FilmKeys.swift); the app's timeline only draws them
// and tells the hand where the pointer is.

extension WindowsCore {
    /// One line of the timeline as it is drawn: the camera, a layer that moves, or one property
    /// of either, and its keys.
    public struct FilmLine: Sendable {
        public let id: String
        public let layer: UUID
        public let camera: Bool
        /// One property's or one shader input's keys alone, on a line opened out of its layer's.
        public let single: Bool
        public let name: String
        /// The layer's kind (Node.Kind), for its glyph; nil for the camera.
        public let kind: String?
        public let marks: [FilmMark]
        /// Whether what it is of is picked: its layer, or the camera.
        public let picked: Bool
        /// Whether its layer's line is opened into one for each property.
        public let open: Bool
    }

    /// A moment with a key on a line.
    public struct FilmMark: Sendable {
        public let t: Double
        /// As designed there: its bead is hollow.
        public let home: Bool
        /// Made by Bezzle to go with a first pose, and not yet touched.
        public let given: Bool
        /// How it is come to from the one before, on a property's own line: how far along the
        /// stretch is when `u` of its time has passed; nil on a layer's line.
        public let pace: (@Sendable (Double) -> Double)?
        public let picked: Bool
        public let hot: Bool
        public var ms: Int { Int((t * 1000).rounded()) }
    }

    /// How far along a key's stretch is, `u` of its time in, as a pace names it: for the pace
    /// chips' curves. `bounce` for a spring.
    nonisolated public static func paceProgress(_ name: String, _ u: Double, bounce: Double = 0.55) -> Double {
        guard let kind = MotionEase.Kind(rawValue: name) else { return u }
        return MotionEase.progress(kind, u, bounce: bounce)
    }

    nonisolated static func progress(_ pace: MotionTrack.Pace, _ u: Double) -> Double {
        switch pace {
        case .curve(let kind, let bounce): MotionEase.progress(kind, u, bounce: bounce)
        case .setOff: MotionEase.setOff(u)
        case .setDown: MotionEase.setDown(u)
        case .onward: u
        }
    }

    @MainActor public final class FilmHand {
        public let desk: FilmDesk
        /// How wide the sheet is, in points: where moments lie along it.
        public var width: CGFloat = 400
        /// The seconds the card shows, held as they were while something is dragged.
        public private(set) var held: Double?
        /// Shown again: what the pointer is on, or what is in hand, changed.
        public var changed: () -> Void = {}

        public init(desk: FilmDesk) { self.desk = desk }

        /// How near the pointer takes a bead, and how near a moment catches the playhead.
        public static let reach: CGFloat = 7
        public static let rowHeight: CGFloat = 24

        /// What the pointer is on.
        public struct Hot: Equatable {
            var key: FilmKeyRef?
            public var band: String?
            public var row: String?
            public var x: CGFloat = 0
            /// On the flag at the film's end.
            public var end = false
            public init() {}
        }

        public var hot = Hot() { didSet { if hot != oldValue { changed() } } }

        struct Drag: Equatable {
            enum Kind { case scrub, keys, band, length, nothing }
            var kind: Kind
            var refs: [FilmKeyRef] = []
            var anchor = 0.0
            var moved = false
            var caught: Double?
        }

        private var drag: Drag?
        public var dragging: Bool { drag != nil }
        /// A band taken in hand, for its pointer.
        public var holdsBand: Bool { drag?.kind == .band }
        public var holdsLength: Bool { drag?.kind == .length }

        /// The seconds the sheet shows.
        public var span: Double { held ?? FilmScale.span(for: desk.length) }

        var scale: FilmScale { FilmScale(width: width, span: span) }

        public func x(_ t: Double) -> CGFloat { scale.x(t) }
        public func t(_ x: CGFloat) -> Double { scale.t(x) }
        public var perSecond: CGFloat { scale.perSecond }

        /// The lines as they were last read, kept while the design, the artboard and the lines
        /// opened are as they were: a scrub asks for them at every step.
        private var rowsWorkedOut: (version: Int, fronts: [UUID: Int], board: UUID, open: Set<UUID>, rows: [FilmRow])?

        private var rows: [FilmRow] {
            guard let board = desk.filmBoard else { return [] }
            if let had = rowsWorkedOut, had.version == WindowsCore.designVersion, had.fronts == WindowsCore.fronts, had.board == board.id, had.open == desk.open {
                return had.rows
            }
            let rows = FilmRow.rows(of: board, open: desk.open)
            rowsWorkedOut = (WindowsCore.designVersion, WindowsCore.fronts, board.id, desk.open, rows)
            return rows
        }

        private func picked(_ row: FilmRow) -> Bool {
            row.camera ? desk.camera : desk.selection.contains(row.layer)
        }

        /// The lines, as they are drawn.
        public func lines() -> [FilmLine] {
            let keys = desk.keys
            var out: [FilmLine] = []
            for row in rows {
                var picks = Set<Int>()
                for ref in keys where row.holds(ref) { picks.insert(ref.ms) }
                var hotMs: Int?
                if hot.row == row.id { hotMs = hot.key?.ms }
                var marks: [FilmMark] = []
                for m in row.marks {
                    let ms = Int((m.t * 1000).rounded())
                    var pace: (@Sendable (Double) -> Double)?
                    if let p = m.pace {
                        let curve: @Sendable (Double) -> Double = { u in WindowsCore.progress(p, u) }
                        pace = curve
                    }
                    marks.append(FilmMark(t: m.t, home: m.home, given: m.given, pace: pace, picked: picks.contains(ms), hot: hotMs == ms))
                }
                out.append(FilmLine(id: row.id, layer: row.layer, camera: row.camera, single: row.single, name: row.name, kind: row.kind?.rawValue,
                                    marks: marks, picked: picked(row), open: desk.open.contains(row.layer)))
            }
            return out
        }

        // MARK: Pointing

        /// What is under a point of the sheet: a bead within reach, else the band of the line there.
        public func point(_ p: CGPoint) -> Hot {
            point(p, rows: rows)
        }

        private func point(_ p: CGPoint, rows: [FilmRow]) -> Hot {
            var out = Hot()
            out.x = p.x
            let i = Int((p.y / Self.rowHeight).rounded(.down))
            guard rows.indices.contains(i) else { return out }
            let row = rows[i]
            out.row = row.id
            let scale = scale
            let near = row.marks.min { abs(scale.x($0.t) - p.x) < abs(scale.x($1.t) - p.x) }
            if let near, abs(scale.x(near.t) - p.x) <= Self.reach {
                out.key = FilmKeyRef(row.layer, row.property, input: row.input, at: near.t)
            } else if let first = row.marks.first, let last = row.marks.last, last.t > first.t, p.x > scale.x(first.t), p.x < scale.x(last.t) {
                out.band = row.id
            }
            return out
        }

        public func pointRuler(_ p: CGPoint) -> Hot {
            var out = Hot()
            out.x = p.x
            out.end = abs(p.x - scale.x(desk.length)) <= 8
            return out
        }

        private func pick(_ row: FilmRow, adding: Bool = false) {
            if row.camera {
                if !desk.camera { desk.pickCamera() }
            } else if !desk.selection.contains(row.layer) {
                desk.select(adding ? desk.selection + [row.layer] : [row.layer])
            }
        }

        // MARK: Pressing and dragging

        /// A press on the sheet. On a bead it picks its key, with Shift one more or one fewer; on
        /// a line's band it takes the whole motion; twice on a line it sets a key there; anywhere
        /// else it takes the playhead.
        public func press(at p: CGPoint, shift: Bool = false, clicks: Int = 1) {
            let rows = rows
            let at = point(p, rows: rows)
            hot = at
            let row = rows.first { $0.id == at.row }
            if let ref = at.key, let row {
                pick(row, adding: shift)
                var keys = Set(desk.pickedKeys)
                if shift {
                    if keys.contains(ref) { keys.remove(ref) } else { keys.insert(ref) }
                } else if !keys.contains(ref) {
                    keys = [ref]
                }
                desk.keys = keys
                drag = keys.contains(ref) ? Drag(kind: .keys, refs: Array(keys), anchor: ref.time) : Drag(kind: .nothing)
            } else if let row, clicks >= 2 {
                pick(row)
                desk.keys = []
                desk.seek(snapped(scale.t(p.x)))
                if let property = row.property { desk.toggleKey(property.rawValue) } else if let input = row.input { desk.toggleInputKey(input) } else { desk.holdHere() }
                drag = Drag(kind: .nothing)
            } else if at.band != nil, let row {
                pick(row)
                let refs = row.marks.map { FilmKeyRef(row.layer, row.property, input: row.input, at: $0.t) }
                desk.keys = Set(refs)
                drag = Drag(kind: .band, refs: refs, anchor: refs.first?.time ?? 0)
            } else {
                if !desk.keys.isEmpty { desk.keys = [] }
                drag = Drag(kind: .scrub)
            }
            changed()
        }

        /// A press on the ruler: on the flag it takes the film's end, twice lets the film be as
        /// long as its keys again; anywhere else it takes the playhead.
        public func pressRuler(at p: CGPoint, clicks: Int = 1) {
            hot = pointRuler(p)
            guard hot.end else {
                drag = Drag(kind: .scrub)
                return
            }
            if clicks >= 2 {
                desk.setLength(nil)
                drag = Drag(kind: .nothing)
            } else {
                drag = Drag(kind: .length)
            }
            changed()
        }

        /// The press moved on: to `p`, `dx` points from where it began. `free` (Ctrl) lets go of
        /// everything a moment catches on, and `fine` (Alt) steps finer.
        public func dragged(to p: CGPoint, by dx: CGFloat, free: Bool = false, fine: Bool = false) {
            guard var d = drag else { return }
            let rows = Probe.time("hand.rows") { self.rows }
            let scale = scale
            let length = desk.length
            switch d.kind {
            case .nothing:
                break
            case .scrub:
                desk.seek(moment(p.x, scale, rows, free: free, fine: fine, caught: &d.caught, length: length))
            case .keys, .band:
                if !d.moved {
                    guard abs(dx) >= 3 else { break }
                    d.moved = true
                    held = scale.span
                    WindowsCore.beginGesture()
                }
                var to = d.anchor + Double(dx / scale.perSecond)
                if !free {
                    let taken = Set(d.refs.map(\.ms))
                    var stops = [desk.filmTime]
                    for row in rows { for m in row.marks where !taken.contains(FilmKeyRef(row.layer, at: m.t).ms) { stops.append(m.t) } }
                    let near = stops.min { abs($0 - to) < abs($1 - to) }
                    if let near, abs(near - to) * Double(scale.perSecond) <= Double(Self.reach) - 1 {
                        d.caught = near
                        to = near
                    } else {
                        d.caught = nil
                        let grid = fine ? 0.01 : 0.05
                        to = (to / grid).rounded() * grid
                    }
                }
                desk.keys = Set(desk.retime(d.refs, by: to - d.anchor))
            case .length:
                if !d.moved {
                    guard abs(dx) >= 2 else { break }
                    d.moved = true
                    held = scale.span
                    WindowsCore.beginGesture()
                }
                var t = scale.t(p.x)
                let last = desk.lastKey
                if !free {
                    if last > 0, abs(last - t) * Double(scale.perSecond) <= Double(Self.reach) {
                        d.caught = last
                        t = last
                    } else {
                        d.caught = nil
                        let grid = fine ? 0.05 : 0.25
                        t = (t / grid).rounded() * grid
                    }
                }
                t = min(max(t, 0.25), scale.span)
                desk.setLength(MotionTiming.time(t))
            }
            // Only when it changed: the timeline is made again each time it is told, and a hand
            // scrubbing through the film moves on many times a second with nothing else changed.
            guard drag != d else { return }
            drag = d
            // Nor for the playhead catching on a key or letting go of it: the timeline shows
            // nothing of that, and the playhead tells of itself (`FilmDesk.moved`).
            if d.kind != .scrub { Probe.time("hand.changed") { changed() } }
        }

        /// The press let go.
        public func ended(shift: Bool = false) {
            guard let d = drag else { return }
            drag = nil
            switch d.kind {
            case .keys:
                if d.moved { endGesture() } else if !shift { desk.seek(d.anchor) }
            case .band:
                if d.moved { endGesture() } else { desk.seek(snapped(scale.t(hot.x))) }
                desk.keys = []
            case .length:
                if d.moved { endGesture() }
            case .scrub, .nothing:
                break
            }
            held = nil
            changed()
        }

        private func endGesture() {
            WindowsCore.endGesture()
            desk.edited()
        }

        /// A drag put back, as by Escape.
        public func cancel() {
            guard let d = drag else { return }
            drag = nil
            if d.moved, WindowsCore.inGesture {
                WindowsCore.cancelGesture()
                desk.edited()
            }
            held = nil
            changed()
        }

        private func snapped(_ t: Double) -> Double { max((t / 0.05).rounded() * 0.05, 0) }

        private func moment(_ x: CGFloat, _ scale: FilmScale, _ rows: [FilmRow], free: Bool, fine: Bool, caught: inout Double?, length: Double) -> Double {
            let t = min(max(scale.t(x), 0), length)
            guard !free else { return t }
            var stops = [0, length]
            for row in rows { stops.append(contentsOf: row.marks.map(\.t)) }
            if let near = stops.min(by: { abs($0 - t) < abs($1 - t) }), abs(near - t) * Double(scale.perSecond) <= Double(Self.reach) - 1 {
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
        public func menu() -> [MotionHand.MenuItem] {
            let rows = rows
            guard let row = rows.first(where: { $0.id == hot.row }) else { return [] }
            let desk = desk
            pick(row)
            var entries: [MotionHand.MenuItem] = []
            if let ref = hot.key {
                if !desk.keys.contains(ref) { desk.keys = [ref] }
                let shared = desk.sharedEase
                for pace in FilmDesk.paces {
                    entries.append(MotionHand.MenuItem(title: pace.title, shortcut: nil, checked: shared == pace.name, enabled: true) { desk.setEase(pace.name) })
                }
                entries.append(.separator)
                entries.append(MotionHand.MenuItem(title: WindowsCore.say("Remove Key"), shortcut: WindowsCore.say("Delete"), checked: false, enabled: true) { desk.removeKeys() })
            } else {
                let t = snapped(scale.t(hot.x))
                let property = row.property, input = row.input
                desk.keys = []
                entries.append(MotionHand.MenuItem(title: WindowsCore.say("Add Key Here"), shortcut: nil, checked: false, enabled: true) {
                    desk.seek(t)
                    if let property { desk.toggleKey(property.rawValue) } else if let input { desk.toggleInputKey(input) } else { desk.holdHere() }
                })
                entries.append(.separator)
                entries.append(MotionHand.MenuItem(title: WindowsCore.say(row.camera ? "Remove the Camera's Motion" : "Remove Motion"), shortcut: nil, checked: false, enabled: true) {
                    desk.clearMotion()
                })
            }
            return entries
        }

        /// Opens a layer's line into one for each property, or closes it again.
        public func toggleOpen(_ layer: UUID) {
            if desk.open.contains(layer) { desk.open.remove(layer) } else { desk.open.insert(layer) }
        }

        /// A click on a line's name: picks what it is of, with Shift one more or one fewer.
        public func pickLine(_ line: FilmLine, shift: Bool) {
            if line.camera {
                desk.pickCamera()
            } else if shift {
                var ids = desk.selection
                if let i = ids.firstIndex(of: line.layer) { ids.remove(at: i) } else { ids.append(line.layer) }
                desk.select(ids)
            } else {
                desk.select([line.layer])
            }
        }
    }
}
