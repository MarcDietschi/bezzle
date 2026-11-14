import Foundation
import CoreGraphics

// MARK: - Notes in the margin

/// A note about a design, as a draftsman writes one in the margin of a drawing, with a line to
/// what it is about. One that starts a thread is about a layer or an artboard, at a spot on it or
/// round a part of it circled in pencil; the others answer it. Each is kept on its own, so two
/// people answering at once both keep their answer, and editing one never touches another.
nonisolated struct MarginNote: Codable, Hashable, Identifiable, Sendable {
    var id = UUID()
    /// The note this one answers; none for one that starts a thread.
    var thread: UUID?
    /// The layer or artboard it is about; none for a spot on the canvas itself.
    var on: UUID?
    /// Where on it: 0…1 across and down its frame, so the note stays on the same spot as the
    /// layer moves and is resized. On the canvas itself, the point there. For a part circled,
    /// the middle of the loop.
    var at = CGPoint(x: 0.5, y: 0.5)
    /// The part circled, when it is about more than a spot: as `at`, fractions of the layer's
    /// frame (running past 0…1, as a loop drawn round something does), or on the canvas itself.
    var area: CGRect?
    /// Where it was on the canvas when it was last put there, for when its layer is taken away
    /// somewhere this Mac has not seen it go: a spot as a rectangle of no size.
    var place: CGRect?
    var text: String
    /// Who wrote it, as their Mac names them.
    var by: String
    /// Their Mac among those sharing the design (`Sharing.replica`), for their pencil.
    var replica: String?
    /// When it was written, in seconds since 1970.
    var time: Double
    /// A thread talked out and ticked off: it leaves the margin, and can be brought back.
    var done: Bool?

    var startsThread: Bool { thread == nil }
    var isDone: Bool { done == true }
}

nonisolated extension MarginNote {
    /// Puts the note at a canvas point: about the layer given, at that spot on it, or on the canvas.
    mutating func put(at p: CGPoint, on layer: UUID?, in doc: BezzleDocument) {
        area = nil
        place = CGRect(origin: p, size: .zero)
        if let layer, let f = doc.absoluteFrame(of: layer), f.width > 0, f.height > 0 {
            on = layer
            at = CGPoint(x: min(max((p.x - f.minX) / f.width, 0), 1), y: min(max((p.y - f.minY) / f.height, 0), 1))
        } else {
            on = nil
            at = p
        }
    }

    /// Puts the note round a part of the design, on the canvas: about what the loop is round, and
    /// going with it, as fractions of its frame; or on the canvas itself.
    mutating func put(around r: CGRect, in doc: BezzleDocument) {
        place = r
        if let layer = doc.subject(ofArea: r), let f = doc.absoluteFrame(of: layer), f.width > 0, f.height > 0 {
            on = layer
            area = CGRect(x: (r.minX - f.minX) / f.width, y: (r.minY - f.minY) / f.height, width: r.width / f.width, height: r.height / f.height)
            at = CGPoint(x: (r.midX - f.minX) / f.width, y: (r.midY - f.minY) / f.height)
        } else {
            on = nil
            area = r
            at = CGPoint(x: r.midX, y: r.midY)
        }
    }
}

nonisolated extension BezzleDocument {
    var notesByID: [UUID: MarginNote] {
        Dictionary((notes ?? []).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    }

    /// The threads, each its first note followed by its answers, oldest first.
    var threads: [(start: MarginNote, replies: [MarginNote])] {
        let all = notes ?? []
        var replies: [UUID: [MarginNote]] = [:]
        for n in all { if let t = n.thread { replies[t, default: []].append(n) } }
        return all.filter(\.startsThread).sorted { ($0.time, $0.id.uuidString) < ($1.time, $1.id.uuidString) }
            .map { ($0, (replies[$0.id] ?? []).sorted { ($0.time, $0.id.uuidString) < ($1.time, $1.id.uuidString) }) }
    }

    /// Where a note's spot is on the canvas: on its layer, wherever that is now; where it was last
    /// put when the layer has gone; nil when that is not known either.
    func spot(of note: MarginNote) -> CGPoint? {
        guard let on = note.on else { return note.area.map { CGPoint(x: $0.midX, y: $0.midY) } ?? note.at }
        guard let frame = absoluteFrame(of: on) else { return note.place.map { CGPoint(x: $0.midX, y: $0.midY) } }
        if let a = note.area { return Self.inside(a, of: frame).center }
        return CGPoint(x: frame.minX + frame.width * note.at.x, y: frame.minY + frame.height * note.at.y)
    }

    /// The part a note circles, on the canvas, wherever its layer is now.
    func area(of note: MarginNote) -> CGRect? {
        guard let a = note.area else { return nil }
        guard let on = note.on else { return a }
        guard let frame = absoluteFrame(of: on) else { return note.place.flatMap { $0.width > 0 || $0.height > 0 ? $0 : nil } }
        return Self.inside(a, of: frame)
    }

    /// A rectangle given in fractions of a frame, on the canvas.
    static func inside(_ a: CGRect, of frame: CGRect) -> CGRect {
        CGRect(x: frame.minX + a.minX * frame.width, y: frame.minY + a.minY * frame.height,
               width: a.width * frame.width, height: a.height * frame.height)
    }

    /// The sheet a note sits beside: the artboard its layer is on, or the layer itself when it
    /// lies on the canvas, as the top of what holds it. None for a note on the canvas itself.
    func sheet(of note: MarginNote) -> Node? {
        guard let on = note.on, let path = path(of: on) else { return nil }
        return nodes[path.top]
    }

    /// Notes whose thread or layer is gone are left out, as are answers to nothing.
    mutating func repairNotes() {
        guard var all = notes else { return }
        let starts = Set(all.filter(\.startsThread).map(\.id))
        all.removeAll { n in n.thread.map { !starts.contains($0) } ?? false }
        notes = all.isEmpty ? nil : all
    }

    /// Notes about layers taken away in this change stay where those layers were, on the canvas,
    /// so that nothing written is lost with what it was about. Undo puts them back on the layer.
    mutating func keepNotes(since old: BezzleDocument) {
        guard var all = notes, all.contains(where: { $0.on != nil }) else { return }
        var changed = false
        for i in all.indices {
            guard let on = all[i].on, node(on) == nil, let frame = old.absoluteFrame(of: on) else { continue }
            let note = all[i]
            if let a = note.area {
                let r = Self.inside(a, of: frame)
                all[i].area = r
                all[i].at = r.center
                all[i].place = r
            } else {
                let p = CGPoint(x: frame.minX + frame.width * note.at.x, y: frame.minY + frame.height * note.at.y)
                all[i].at = p
                all[i].place = CGRect(origin: p, size: .zero)
            }
            all[i].on = nil
            changed = true
        }
        if changed { notes = all }
    }

    /// What a loop drawn round `area` is about: the biggest layer it holds most of, unless the
    /// loop is far bigger than that; otherwise the smallest layer holding all of it; otherwise
    /// the artboard under its middle. None for a loop drawn on the canvas itself.
    func subject(ofArea area: CGRect) -> UUID? {
        let size = area.width * area.height
        guard size > 0 else { return nil }
        var held: (id: UUID, size: CGFloat)?, holding: (id: UUID, size: CGFloat)?
        func visit(_ nodes: [Node], origin: CGPoint) {
            for n in nodes where !n.hidden {
                let f = n.frame.offsetBy(dx: origin.x, dy: origin.y)
                let s = f.width * f.height
                if !n.isArtboard, s > 0 {
                    let inside = f.intersection(area)
                    let share = inside.isNull ? 0 : inside.width * inside.height / s
                    if share >= 0.6, size <= s * 4, s > (held?.size ?? 0) { held = (n.id, s) }
                    if f.contains(area), s < (holding?.size ?? .infinity) { holding = (n.id, s) }
                }
                if !n.children.isEmpty, n.isContainer { visit(n.children, origin: f.origin) }
            }
        }
        visit(nodes, origin: .zero)
        let middle = CGPoint(x: area.midX, y: area.midY)
        return held?.id ?? holding?.id ?? artboard(at: middle)?.id
    }

    /// The threads still open in the order one goes through them in a review: sheet by sheet,
    /// from the top row down and left to right along it, and down each sheet; those on the canvas
    /// itself last, by where they are.
    var reviewOrder: [UUID] {
        let open = threads.filter { !$0.start.isDone }.map(\.start)
        func key(_ n: MarginNote) -> (Int, CGFloat, CGFloat, CGFloat, CGFloat, String) {
            let spot = self.spot(of: n) ?? .zero
            guard let sheet = sheet(of: n) else { return (1, spot.y, spot.x, 0, 0, n.id.uuidString) }
            let f = sheet.isArtboard ? sheet.frame : Geometry.bounds(of: sheet)
            return (0, f.minY, f.minX, spot.y, spot.x, n.id.uuidString)
        }
        return open.sorted { key($0) < key($1) }.map(\.id)
    }

    /// Whether a thread holds words written on another Mac since it was last read on this one.
    func unread(_ thread: UUID, seen: Double?, replica: String) -> Bool {
        let all = (notes ?? []).filter { $0.id == thread || $0.thread == thread }
        return all.contains { $0.replica != replica && $0.time > (seen ?? 0) }
    }
}

// MARK: - The loop round a part

/// The loop a hand draws round part of a sheet to say "this", as on a printout: near the shape
/// of what it circles, never quite round, its end running on past its start. Each note's is its
/// own, from its seed. Points round a rectangle, a little wider than it.
nonisolated enum NoteLoop {
    static let samples = 64

    /// How far out of the rectangle the loop runs, at the middle of each side.
    static func radii(of r: CGRect) -> CGSize {
        CGSize(width: r.width / 2 * 1.16 + 7, height: r.height / 2 * 1.2 + 7)
    }

    static func points(seed: UInt64, around r: CGRect) -> [CGPoint] {
        var s = seed &* 0x9E37_79B9_7F4A_7C15 | 1
        func random() -> Double {
            s ^= s >> 12; s ^= s << 25; s ^= s >> 27
            return Double((s &* 0x2545_F491_4F6C_DD1D) >> 11) / Double(UInt64(1) << 53)
        }
        let start = -2.4 + random() * 0.5
        let sweep = 2 * Double.pi + 0.42 + random() * 0.3
        let tilt = -0.035 + random() * 0.03
        let p1 = random() * 6.28, p2 = random() * 6.28
        let radii = radii(of: r)
        let c = CGPoint(x: r.midX, y: r.midY)
        return (0...samples).map { i in
            let f = Double(i) / Double(samples)
            let a = start + sweep * f
            // Wavering as a hand does, and opening out a little as it comes round again.
            let wobble = 1 + 0.03 * sin(1.7 * a + p1) + 0.018 * sin(3.1 * a + p2) + 0.07 * f * f
            let x = cos(a) * Double(radii.width) * wobble, y = sin(a) * Double(radii.height) * wobble
            return CGPoint(x: c.x + CGFloat(x * cos(tilt) - y * sin(tilt)), y: c.y + CGFloat(x * sin(tilt) + y * cos(tilt)))
        }
    }

    /// Where the loop round `r`, as it is drawn from `seed`, has its thread leave for a card on
    /// that side: its point furthest out that way, on the pencil line itself, so nothing of the
    /// loop runs out past its pin toward the card.
    static func pin(seed: UInt64, around r: CGRect, right: Bool) -> CGPoint {
        let points = points(seed: seed, around: r)
        let far = right ? points.max { $0.x < $1.x } : points.min { $0.x < $1.x }
        return far ?? CGPoint(x: right ? r.maxX : r.minX, y: r.midY)
    }

    static func seed(_ id: UUID) -> UInt64 {
        let u = id.uuid
        return [u.0, u.1, u.2, u.3, u.4, u.5, u.6, u.7].reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
    }
}

// MARK: - Shared

nonisolated extension MarginNote {
    /// Its properties as a shared design keeps them, each changed on its own, as a style's are.
    static let threadField = "note.thread", onField = "note.on", atField = "note.at", textField = "note.text"
    static let byField = "note.by", replicaField = "note.replica", timeField = "note.time", doneField = "note.done"
    static let areaField = "note.area", placeField = "note.place"
    static let goneField = "note.gone"

    func fields() -> [String: FieldValue] {
        func rect(_ r: CGRect?) -> FieldValue {
            guard let r else { return .null }
            let values: [Double] = [Double(r.minX), Double(r.minY), Double(r.width), Double(r.height)]
            return .array(values.map { FieldValue.number($0) })
        }
        var out: [String: FieldValue] = [:]
        out[Self.threadField] = thread.map { FieldValue.string($0.uuidString) } ?? .null
        out[Self.onField] = on.map { FieldValue.string($0.uuidString) } ?? .null
        out[Self.atField] = .array([.number(Double(at.x)), .number(Double(at.y))])
        out[Self.areaField] = rect(area)
        out[Self.placeField] = rect(place)
        out[Self.textField] = .string(text)
        out[Self.byField] = .string(by)
        out[Self.replicaField] = replica.map { FieldValue.string($0) } ?? .null
        out[Self.timeField] = .number(time)
        out[Self.doneField] = .bool(isDone)
        out[Self.goneField] = .bool(false)
        return out
    }

    /// When it was taken away, unless something about it changed since; nil while it is there.
    static func gone(_ layer: SharedLayer) -> Stamp? {
        guard let gone = layer.fields[goneField], gone.value == .bool(true),
              !layer.fields.contains(where: { $0.key != goneField && $0.value.stamp > gone.stamp }) else { return nil }
        return gone.stamp
    }

    /// The note a shared design keeps under `id`, unless it was taken away and nothing about it
    /// changed since (or even then, `evenGone`); nil too for what is no note.
    static func read(_ id: UUID, from layer: SharedLayer, evenGone: Bool = false) -> MarginNote? {
        guard layer.place == nil, case .string(let text)? = layer.fields[textField]?.value else { return nil }
        if !evenGone, gone(layer) != nil { return nil }
        func uuid(_ field: String) -> UUID? {
            if case .string(let s)? = layer.fields[field]?.value { return UUID(uuidString: s) }
            return nil
        }
        func rect(_ field: String) -> CGRect? {
            guard case .array(let v)? = layer.fields[field]?.value, v.count == 4,
                  case .number(let x) = v[0], case .number(let y) = v[1], case .number(let w) = v[2], case .number(let h) = v[3] else { return nil }
            return CGRect(x: x, y: y, width: w, height: h)
        }
        var note = MarginNote(id: id, thread: uuid(threadField), on: uuid(onField), text: text, by: "", time: 0)
        if case .array(let xy)? = layer.fields[atField]?.value, xy.count == 2, case .number(let x) = xy[0], case .number(let y) = xy[1] {
            note.at = CGPoint(x: x, y: y)
        }
        note.area = rect(areaField)
        note.place = rect(placeField)
        if case .string(let by)? = layer.fields[byField]?.value { note.by = by }
        if case .string(let r)? = layer.fields[replicaField]?.value { note.replica = r }
        if case .number(let t)? = layer.fields[timeField]?.value { note.time = t }
        if case .bool(true)? = layer.fields[doneField]?.value { note.done = true }
        return note
    }
}
