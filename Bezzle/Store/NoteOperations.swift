import AppKit
import QuartzCore

/// Writing in the margin: notes about layers and artboards, answers to them, and ticking a
/// thread off once it is talked out. Every one is a step of the undo history, and shared as any
/// change is (see `MarginNote`).
extension DocumentStore {
    /// Who writes here, as the others see them.
    var noteAuthor: (name: String, replica: String) {
        (sharing?.live?.name ?? LiveRoom.myName, sharing?.replica ?? CloudSync.replica)
    }

    /// Starts a note at a canvas point, about the layer there if any: it is written in the margin
    /// beside it, and posted with Return.
    func beginNote(at p: CGPoint, on id: UUID?) {
        guard !isReadOnly else { return }
        let (name, replica) = noteAuthor
        var note = MarginNote(text: "", by: name, replica: replica, time: Date().timeIntervalSince1970)
        note.put(at: p, on: id, in: doc)
        start(note)
    }

    /// Starts a note about the part of the design circled, on the canvas: about the layer the
    /// loop is round, and staying round it as that moves.
    func beginNote(around area: CGRect) {
        guard !isReadOnly, area.width > 0 || area.height > 0 else { return }
        let (name, replica) = noteAuthor
        var note = MarginNote(text: "", by: name, replica: replica, time: Date().timeIntervalSince1970)
        // A loop drawn along a line still has some height to go round.
        let r = area.standardized
        note.put(around: r.insetBy(dx: min(r.width - 2, 0) / 2, dy: min(r.height - 2, 0) / 2), in: doc)
        start(note)
    }

    private func start(_ note: MarginNote) {
        noteCircle = nil
        openThread = nil
        draftNote = note
        tool = .select
    }

    /// Posts the note being written; with no words, it is simply let go.
    func postNote(_ text: String) {
        guard var note = draftNote else { return }
        draftNote = nil
        let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty else { return }
        note.text = words
        note.time = Date().timeIntervalSince1970
        edit("Write Note") { doc in doc.notes = (doc.notes ?? []) + [note] }
        openThread = note.id
        notesSeen.read(note.id)
    }

    func answer(_ thread: UUID, _ text: String) {
        let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty, doc.notesByID[thread]?.startsThread == true else { return }
        let (name, replica) = noteAuthor
        let note = MarginNote(thread: thread, text: words, by: name, replica: replica, time: Date().timeIntervalSince1970)
        edit("Answer Note") { doc in doc.notes = (doc.notes ?? []) + [note] }
        notesSeen.read(thread)
    }

    /// Ticks a thread off, which leaves the margin, or brings it back.
    func setDone(_ thread: UUID, _ done: Bool) {
        guard doc.notesByID[thread]?.startsThread == true else { return }
        edit(done ? "Close Note" : "Open Note Again") { doc in
            if let i = doc.notes?.firstIndex(where: { $0.id == thread }) { doc.notes?[i].done = done ? true : nil }
        }
        if done, openThread == thread { openThread = nil }
    }

    func changeNote(_ id: UUID, _ text: String) {
        let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty else { return }
        edit("Change Note") { doc in
            if let i = doc.notes?.firstIndex(where: { $0.id == id }) { doc.notes?[i].text = words }
        }
    }

    /// Takes a note away; one that starts a thread takes its answers with it.
    func deleteNote(_ id: UUID) {
        edit("Delete Note") { doc in
            doc.notes?.removeAll { $0.id == id || $0.thread == id }
            if doc.notes?.isEmpty == true { doc.notes = nil }
        }
        if openThread == id { openThread = nil }
    }

    /// Puts a thread's spot somewhere else: on the layer now under it, or on the canvas. A loop
    /// goes along with its spot, and is about whatever it is round there.
    func moveNote(_ id: UUID, to p: CGPoint, on layer: UUID?) {
        edit("Move Note") { doc in
            guard let i = doc.notes?.firstIndex(where: { $0.id == id }) else { return }
            var note = doc.notes![i]
            if let area = doc.area(of: note) {
                note.put(around: area.offsetBy(dx: p.x - area.midX, dy: p.y - area.midY), in: doc)
            } else {
                note.put(at: p, on: layer, in: doc)
            }
            doc.notes?[i] = note
        }
    }

    /// Whether a note was written on this Mac, so it may be changed or taken away here.
    func wrote(_ note: MarginNote) -> Bool { note.replica == noteAuthor.replica }

    // MARK: Reading

    /// Opens a thread and puts the typing in its answer, or in the words of one of its notes, as
    /// a menu asks.
    func focusNote(_ focus: NoteFocus) {
        guard !isReadOnly else { return }
        let thread: UUID?
        switch focus {
        case .answer(let id): thread = id
        case .change(let id): thread = doc.notesByID[id].map { $0.thread ?? $0.id }
        }
        guard let thread, doc.notesByID[thread] != nil else { return }
        draftNote = nil
        if openThread != thread { openThread = thread }
        notesSeen.read(thread)
        noteFocus = focus
    }

    /// Opens a thread in the margin, or closes the one open.
    func toggleThread(_ id: UUID) {
        openThread = openThread == id ? nil : id
        if openThread == id { notesSeen.read(id) }
    }

    /// Whether a thread holds words from elsewhere not read here yet.
    func isUnread(_ thread: UUID) -> Bool {
        doc.unread(thread, seen: notesSeen[thread], replica: noteAuthor.replica)
    }

    /// Goes to a thread, the view flying there if it is out of sight, and opens it.
    func showThread(_ id: UUID) {
        guard let note = doc.notesByID[id], let spot = doc.spot(of: note) else { return }
        draftNote = nil
        openThread = id
        notesSeen.read(id)
        let home = doc.sheet(of: note).map { $0.isArtboard ? $0.frame : Geometry.bounds(of: $0) }
        if let target = NotesView.target(showing: spot, area: doc.area(of: note), home: home, from: viewport, in: canvasSize) {
            glide.fly(self, to: target)
        }
    }

    /// The thread before or after the one open, in review order, going round.
    func stepThread(by step: Int) {
        let order = doc.reviewOrder
        guard !order.isEmpty else { return }
        let i = openThread.flatMap { order.firstIndex(of: $0) }
        let next = i.map { (($0 + step) % order.count + order.count) % order.count } ?? (step >= 0 ? 0 : order.count - 1)
        showThread(order[next])
    }
}

/// Where the typing goes in a note, asked for from its menu.
enum NoteFocus: Equatable {
    /// Into the thread's answer.
    case answer(UUID)
    /// Into the words of this note, to change them.
    case change(UUID)
}

/// When each thread of a design was last read on this Mac, kept with the Mac's own settings:
/// what is new is new to each reader.
@MainActor
final class NotesSeen {
    private let key: String
    private var times: [String: Double]

    init(key: String) {
        self.key = "NotesSeen." + key
        times = UserDefaults.standard.dictionary(forKey: self.key) as? [String: Double] ?? [:]
    }

    subscript(_ thread: UUID) -> Double? { times[thread.uuidString] }

    func read(_ thread: UUID) {
        times[thread.uuidString] = Date().timeIntervalSince1970
        UserDefaults.standard.set(times, forKey: key)
    }
}

/// Where the view goes to show a note.
nonisolated enum NotesView {
    /// The view that shows a note's spot with room for its card beside it: the view there is, moved
    /// just as far as it takes, closer in when it is too far out to read the sheet; nil when the
    /// note is in sight already.
    static func target(showing spot: CGPoint, area: CGRect?, home: CGRect?, from vp: Viewport, in size: CGSize) -> Viewport? {
        guard size.width > 0, size.height > 0 else { return nil }
        var zoom = vp.zoom
        if let home, home.height * zoom < 260 {
            // Too far out to read: in, until the sheet fills most of the height, no further than actual size.
            zoom = max(zoom, min(size.height * 0.7 / max(home.height, 1), 1))
        }
        zoom = min(max(zoom, Viewport.minZoom), Viewport.maxZoom)
        let focus = (area ?? CGRect(origin: spot, size: .zero)).insetBy(dx: -40 / zoom, dy: -40 / zoom)
        // The card's strip of margin, on the side of its sheet nearer the spot.
        let card = (NotePlacement.gap + NotePlacement.width + 24) / zoom
        var need = focus
        if let home {
            let right = spot.x >= home.midX
            need = need.union(CGRect(x: right ? home.maxX : home.minX - card, y: focus.minY, width: card, height: focus.height))
        } else {
            need = need.union(CGRect(x: focus.maxX, y: focus.minY, width: card, height: focus.height))
        }
        let visible = CGRect(origin: vp.origin, size: CGSize(width: size.width / vp.zoom, height: size.height / vp.zoom))
        if zoom == vp.zoom, visible.contains(need) { return nil }
        let view = CGSize(width: size.width / zoom, height: size.height / zoom)
        let middle = need.width <= view.width && need.height <= view.height ? CGPoint(x: need.midX, y: need.midY) : CGPoint(x: focus.midX, y: focus.midY)
        return Viewport(origin: CGPoint(x: middle.x - view.width / 2, y: middle.y - view.height / 2), zoom: zoom)
    }
}

/// Moves a canvas's view in flight to another, by the way that feels shortest. A display link of
/// the canvas's own, running only while the view moves; the view moved by hand lets go.
@MainActor
final class CanvasGlide: NSObject {
    private weak var store: DocumentStore?
    private var link: CADisplayLink?
    private var flight: CameraFlight?
    private var began: CFTimeInterval = 0
    private var set: Viewport?

    var flying: Bool { flight != nil }

    func fly(_ store: DocumentStore, to target: Viewport) {
        self.store = store
        let size = store.canvasSize
        flight = CameraFlight(from: store.viewport.shot(in: size), to: target.shot(in: size))
        began = CACurrentMediaTime()
        set = store.viewport
        guard link == nil, let canvas = store.canvas else {
            if store.canvas == nil { store.viewport = target; stop() }
            return
        }
        let link = canvas.displayLink(target: self, selector: #selector(step))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    func stop() {
        link?.invalidate()
        link = nil
        flight = nil
        set = nil
    }

    @objc private func step(_ link: CADisplayLink) {
        guard let store, let flight else { return stop() }
        if let set, set != store.viewport { return stop() }
        let f = (CACurrentMediaTime() - began) / flight.duration
        let v = Viewport(flight.shot(at: f), in: store.canvasSize)
        store.viewport = v
        set = store.viewport
        if f >= 1 { stop() }
    }
}
