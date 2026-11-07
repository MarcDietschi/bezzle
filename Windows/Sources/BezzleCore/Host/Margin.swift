import Foundation

// Notes in the margin on Windows, as the Mac's NoteOperations and NotesLayer have them: notes
// about layers and artboards, answers to them, ticking a thread off once it is talked out. Where
// each thread goes is the shared NotePlacement; how it moves there is the Mac's NoteMotion,
// ported: springs for the cards, a spring carrying a pulled pin, a loose one for each thread's
// sag, and the clock for threads being written in and ticked off. The cards are the app's; their
// heights come from how many lines their words take, which the app measures.

extension WindowsCore.FlowSpring {
    var resting: Bool { hypot(velocity.dx, velocity.dy) < 4 }
}

extension WindowsCore {
    /// The pencil a person would rather have, the same on every computer (the Mac's
    /// Pencil.preferred), as its sRGB.
    public static func pencil(of replica: String) -> UInt32 {
        let colours: [UInt32] = [0xE14C30, 0xD9951B, 0x1B9C75, 0xD9437E, 0x1494B3, 0xA6663C, 0x6B9928, 0x9D3FA6]
        let hash = SHA256.hash(data: Data(replica.utf8)).prefix(4).reduce(0) { $0 << 8 | Int($1) }
        return colours[hash % colours.count]
    }

    /// Who writes here, kept with Bezzle's own settings: a name, and this computer's replica,
    /// made once.
    static let noteAuthor: (name: String, replica: String) = {
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Bezzle", isDirectory: true)
        let file = folder?.appendingPathComponent("replica.txt")
        var replica = file.flatMap { try? String(contentsOf: $0, encoding: .utf8) }?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if replica.isEmpty, let folder, let file {
            replica = UUID().uuidString
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try? replica.write(to: file, atomically: true, encoding: .utf8)
        }
        let full = ProcessInfo.processInfo.fullUserName
        let name = full.isEmpty ? ProcessInfo.processInfo.userName : full
        return (name.isEmpty ? "Me" : name, replica)
    }()

    /// When each thread of a design was last read here: what is new is new to each reader.
    final class NotesSeen {
        private let url: URL?
        private var times: [String: Double]

        init(design: String) {
            let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
                .appendingPathComponent("Bezzle", isDirectory: true).appendingPathComponent("NotesSeen", isDirectory: true)
            let name = String(SHA256.hash(data: Data(design.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined())
            url = folder?.appendingPathComponent(name + ".json")
            times = url.flatMap { try? Data(contentsOf: $0) }.flatMap { try? JSONDecoder().decode([String: Double].self, from: $0) } ?? [:]
            if let folder { try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        }

        subscript(_ thread: UUID) -> Double? { times[thread.uuidString] }

        func read(_ thread: UUID) {
            times[thread.uuidString] = Date().timeIntervalSince1970
            if let url, let data = try? JSONEncoder().encode(times) { try? data.write(to: url) }
        }
    }

    /// Writing in the margin, and the margin as it shows, for one design window.
    @MainActor public final class NotesHand {
        /// The note being written, before it is posted.
        private(set) var draft: MarginNote?
        public var draftID: UUID? { draft?.id }
        public var openThread: UUID? { didSet { if openThread != oldValue { redraw() } } }
        /// The loop being drawn with the note tool, on the canvas.
        public var circle: CGRect? { didSet { if circle != oldValue { redraw() } } }
        /// With the note tool out, ticked-off threads show as faint flags.
        public var showDone = false { didSet { if showDone != oldValue { redraw() } } }
        /// Where the typing goes in a note, asked for from its menu.
        public enum Focus: Equatable { case answer(UUID), change(UUID) }
        public var focus: Focus?
        public var redraw: () -> Void = {}
        /// How many lines words take on a card, up to a limit, and how tall a line is: the app
        /// measures them as it sets them.
        public var lines: (String, Int?) -> Int = { _, _ in 1 }
        public var lineHeight: Double = 18
        let motion = NoteMotion()
        private var seen: NotesSeen?

        public init() {}

        private var doc: BezzleDocument? { WindowsCore.design }
        public var author: (name: String, replica: String) { WindowsCore.noteAuthor }

        /// The design opened: what has been read of it here.
        public func opened(_ path: String) { seen = NotesSeen(design: path) }

        // MARK: Writing

        /// Starts a note at a canvas point, about the layer there if any: it is written in the
        /// margin beside it, and posted with Enter.
        public func begin(at p: CGPoint, on id: UUID?) {
            guard let doc else { return }
            var note = MarginNote(text: "", by: author.name, replica: author.replica, time: Date().timeIntervalSince1970)
            note.put(at: p, on: id, in: doc)
            start(note)
        }

        /// Starts a note about the part of the design circled: about the layer the loop is
        /// round, and staying round it as that moves.
        public func begin(around area: CGRect) {
            guard let doc, area.width > 0 || area.height > 0 else { return }
            var note = MarginNote(text: "", by: author.name, replica: author.replica, time: Date().timeIntervalSince1970)
            // A loop drawn along a line still has some height to go round.
            let r = area.standardized
            note.put(around: r.insetBy(dx: min(r.width - 2, 0) / 2, dy: min(r.height - 2, 0) / 2), in: doc)
            start(note)
        }

        private func start(_ note: MarginNote) {
            circle = nil
            openThread = nil
            draft = note
            redraw()
        }

        /// The note being written let go of.
        public func dropDraft() {
            draft = nil
            redraw()
        }

        /// Posts the note being written; with no words, it is simply let go. Whether a step was made.
        @discardableResult public func post(_ text: String) -> Bool {
            guard var note = draft else { return false }
            draft = nil
            let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !words.isEmpty else { redraw(); return false }
            note.text = words
            note.time = Date().timeIntervalSince1970
            WindowsCore.edit { $0.notes = ($0.notes ?? []) + [note] }
            openThread = note.id
            seen?.read(note.id)
            return true
        }

        @discardableResult public func answer(_ thread: UUID, _ text: String) -> Bool {
            let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !words.isEmpty, doc?.notesByID[thread]?.startsThread == true else { return false }
            let note = MarginNote(thread: thread, text: words, by: author.name, replica: author.replica, time: Date().timeIntervalSince1970)
            WindowsCore.edit { $0.notes = ($0.notes ?? []) + [note] }
            seen?.read(thread)
            return true
        }

        /// Ticks a thread off, which leaves the margin, or brings it back.
        public func setDone(_ thread: UUID, _ done: Bool) {
            guard doc?.notesByID[thread]?.startsThread == true else { return }
            WindowsCore.edit { doc in
                if let i = doc.notes?.firstIndex(where: { $0.id == thread }) { doc.notes?[i].done = done ? true : nil }
            }
            if done, openThread == thread { openThread = nil }
        }

        public func change(_ id: UUID, _ text: String) {
            let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !words.isEmpty else { return }
            WindowsCore.edit { doc in
                if let i = doc.notes?.firstIndex(where: { $0.id == id }) { doc.notes?[i].text = words }
            }
        }

        /// Takes a note away; one that starts a thread takes its answers with it.
        public func delete(_ id: UUID) {
            WindowsCore.edit { doc in
                doc.notes?.removeAll { $0.id == id || $0.thread == id }
                if doc.notes?.isEmpty == true { doc.notes = nil }
            }
            if openThread == id { openThread = nil }
        }

        /// Puts a thread's spot somewhere else: on the layer now under it, or on the canvas. A
        /// loop goes along with its spot, and is about whatever it is round there.
        public func move(_ id: UUID, to p: CGPoint, on layer: UUID?) {
            WindowsCore.edit { doc in
                guard let i = doc.notes?.firstIndex(where: { $0.id == id }) else { return }
                var note = doc.notes![i]
                if let area = doc.area(of: note) {
                    note.put(around: area.offsetBy(dx: p.x - area.midX, dy: p.y - area.midY), in: doc)
                } else {
                    note.put(at: p, on: layer, in: doc)
                }
                doc.notes?[i] = note
            }
            motion.caught(id)
        }

        /// What a pin pulled to a canvas point would land on: for a loop, what it would be round.
        public func landing(_ id: UUID, at p: CGPoint, layerAt: (CGPoint) -> UUID?) -> UUID? {
            guard let doc, let note = doc.notesByID[id] else { return nil }
            if let area = doc.area(of: note) {
                return doc.subject(ofArea: area.offsetBy(dx: p.x - area.midX, dy: p.y - area.midY))
            }
            return layerAt(p) ?? doc.artboard(at: p)?.id
        }

        /// Where a thread's spot is on the canvas, and whether it is a loop.
        public func spot(of id: UUID) -> (spot: CGPoint, loop: Bool)? {
            guard let doc, let note = doc.notesByID[id], let spot = doc.spot(of: note) else { return nil }
            return (spot, doc.area(of: note) != nil)
        }

        /// Whether a note was written here, so it may be changed or taken away here.
        func wrote(_ note: MarginNote) -> Bool { note.replica == author.replica }

        // MARK: Reading

        /// Opens a thread and puts the typing in its answer, or in the words of one of its notes.
        public func focus(_ f: Focus) {
            let thread: UUID?
            switch f {
            case .answer(let id): thread = id
            case .change(let id): thread = doc?.notesByID[id].map { $0.thread ?? $0.id }
            }
            guard let thread, doc?.notesByID[thread] != nil else { return }
            draft = nil
            openThread = thread
            seen?.read(thread)
            focus = f
            redraw()
        }

        /// Opens a thread in the margin, or closes the one open.
        public func toggle(_ id: UUID) {
            openThread = openThread == id ? nil : id
            if openThread == id { seen?.read(id) }
        }

        public func isUnread(_ thread: UUID) -> Bool {
            doc?.unread(thread, seen: seen?[thread], replica: author.replica) ?? false
        }

        /// The thread before or after the one open, in review order, going round: where its spot is.
        public func step(by step: Int) -> CGPoint? {
            guard let doc else { return nil }
            let order = doc.reviewOrder
            guard !order.isEmpty else { return nil }
            let i = openThread.flatMap { order.firstIndex(of: $0) }
            let next = i.map { (($0 + step) % order.count + order.count) % order.count } ?? (step >= 0 ? 0 : order.count - 1)
            let id = order[next]
            draft = nil
            openThread = id
            seen?.read(id)
            return doc.notesByID[id].flatMap { doc.spot(of: $0) }
        }

        /// How many threads a review goes through.
        public var reviewCount: Int { doc?.reviewOrder.count ?? 0 }

        /// What a thread says, for the clipboard.
        public func words(of thread: UUID) -> String {
            guard let doc, let t = doc.threads.first(where: { $0.start.id == thread }) else { return "" }
            return ([t.start] + t.replies).map { "\($0.by): \($0.text)" }.joined(separator: "\n\n")
        }

        // MARK: The margin as it shows

        /// A thread as the margin shows it.
        /// A note as a card shows it.
        public struct NoteLook {
            public let id: UUID
            public let text: String
            public let by: String
            public let time: Double
            /// Written here: it may be changed or taken away here.
            public let mine: Bool
            public let colour: UInt32
            /// The writer's initial, for their token.
            public var initial: String { by.first.map { String($0).uppercased() } ?? "•" }
        }

        public struct Item {
            var start: MarginNote
            var replies: [MarginNote]
            /// The first note and its answers, as the card shows them.
            public var notes: [NoteLook] = []
            public var id: UUID { start.id }
            public var draft = false
            public var open = false
            public var done = false
            public var unread = false
            /// Its writer's pencil.
            public var colour: UInt32
        }

        /// A thread where it is on screen this frame, on its way to where it goes.
        public struct Shown {
            public var id: UUID
            public var key: String
            public var item: Item
            var place: NotePlacement.Place
            public var frame: CGRect
            public var anchor: CGPoint
            public var pin: CGPoint
            public var area: CGRect?
            public var sag: CGFloat = 0
            /// How far it is written in, 0…1.
            public var born: Double = 1
            /// How far it has gone, 0…1, once it has.
            public var leaving: Double?
            public var tickedOff = false
            /// Coming or going as a card folds to a flag or a flag unfolds to a card, in place.
            public var turned = false
            public var lit = false
            public var dragged = false
            /// What kind of piece it is: "card", "lifted", "flag" or "pin".
            public var kind: String {
                switch place.kind {
                case .card: "card"
                case .lifted: "lifted"
                case .flag: "flag"
                case .pin: "pin"
                }
            }
            public var right: Bool { place.side == .right }
        }

        public struct Scene {
            public var shown: [Shown] = []
            public var ghosts: [Shown] = []
            /// The loop being drawn with the note tool, on screen.
            public var circle: CGRect?
            public var isEmpty: Bool { shown.isEmpty && ghosts.isEmpty && circle == nil }
        }

        /// A pin being pulled: whose, and how far from where it was, on screen.
        public struct Drag: Equatable {
            public let id: UUID
            public var by: CGSize
            public var over: UUID?
            public init(id: UUID, by: CGSize, over: UUID? = nil) { self.id = id; self.by = by; self.over = over }
        }

        public var moving: Bool { motion.moving }

        /// The margin as it is this frame, as the Mac's NotesLayer.scene: where every thread goes
        /// (`NotePlacement`), and where it is on its way there (`NoteMotion`). Open cards are as
        /// tall as they were last drawn (`heights`); shut ones as their words make them.
        public func scene(zoom: CGFloat, pan: CGPoint, heights: [UUID: CGFloat], drag: Drag?, pointed: UUID?,
                          now: Double = WindowsCore.now) -> Scene {
            guard let doc else { return Scene() }
            func view(_ p: CGPoint) -> CGPoint { CGPoint(x: pan.x + p.x * zoom, y: pan.y + p.y * zoom) }
            func view(_ r: CGRect) -> CGRect { CGRect(origin: view(r.origin), size: CGSize(width: r.width * zoom, height: r.height * zoom)) }
            var list = doc.threads.filter { showDone || !$0.start.isDone }.map { (start: $0.start, replies: $0.replies, draft: false) }
            if let d = draft { list.append((d, [], true)) }
            if list.isEmpty && motion.idle && circle == nil { return Scene() }
            // Every sheet, near or far: where a card goes must not depend on what is in sight.
            let obstacles = doc.nodes.filter { !$0.hidden }.map { view($0.isArtboard ? $0.frame : Geometry.bounds(of: $0)) }
            var wants: [NotePlacement.Want] = []
            var items: [UUID: (item: Item, spot: CGPoint, area: CGRect?)] = [:]
            for (start, replies, isDraft) in list {
                guard var spot = doc.spot(of: start).map(view) else { continue }
                var area = doc.area(of: start).map(view)
                if let drag, drag.id == start.id {
                    // Pulled away, its spot leads the card along.
                    spot = CGPoint(x: spot.x + drag.by.width, y: spot.y + drag.by.height)
                    area = area?.offsetBy(dx: drag.by.width, dy: drag.by.height)
                }
                let sheet = doc.sheet(of: start)
                let home = sheet.map { view($0.isArtboard ? $0.frame : Geometry.bounds(of: $0)) }
                let open = isDraft || openThread == start.id
                var item = Item(start: start, replies: replies, draft: isDraft, open: open, done: start.isDone,
                                unread: !isDraft && isUnread(start.id), colour: colour(of: start))
                item.notes = ([start] + replies).map { NoteLook(id: $0.id, text: $0.text, by: $0.by, time: $0.time, mine: wrote($0), colour: colour(of: $0)) }
                wants.append(NotePlacement.Want(id: start.id, spot: area.map { CGPoint(x: $0.midX, y: $0.midY) } ?? spot, home: home,
                                                sheet: sheet?.id, height: height(start, replies, open: open, draft: isDraft, heights: heights),
                                                open: open, flagOnly: start.isDone, area: area))
                items[start.id] = (item, spot, area)
            }
            let places = NotePlacement.place(wants, around: obstacles, was: motion.kinds)
            return motion.settle(places, items, drag: drag, pointed: pointed, view: (zoom, pan), circle: circle.map(view),
                                 done: Set(doc.threads.filter(\.start.isDone).map(\.start.id)), now: now)
        }

        /// A writer's pencil: this computer's writer in Bezzle's own, anyone else in theirs.
        func colour(of note: MarginNote) -> UInt32 {
            guard let replica = note.replica, !wrote(note) else { return 0x3559C7 }
            return WindowsCore.pencil(of: replica)
        }

        // MARK: How tall a card is (the Mac's NoteCardSize)

        public static let padding: CGFloat = 10
        public static let header: CGFloat = 16
        public static let spacing: CGFloat = 9
        public static let textSize: CGFloat = 12.5
        public static let leading: CGFloat = (textSize * 0.5).rounded() / 2
        public static let answeredRow: CGFloat = 14
        public static let composer: CGFloat = 32
        /// The words' width: the card's, less its padding.
        public static let measure = NotePlacement.width - 22
        public static let draftHeight: CGFloat = 2 * padding + header + spacing + 20

        private func words(_ text: String, limit: Int?) -> CGFloat {
            let n = CGFloat(max(1, lines(text, limit)))
            return n * CGFloat(lineHeight) + (n - 1) * Self.leading
        }

        private func note(_ text: String, limit: Int?) -> CGFloat { Self.header + 4 + words(text, limit: limit) }

        private func height(_ start: MarginNote, _ replies: [MarginNote], open: Bool, draft: Bool, heights: [UUID: CGFloat]) -> CGFloat {
            if draft { return heights[start.id] ?? Self.draftHeight }
            if open {
                if let h = heights[start.id] { return h }
                let notes = ([start] + replies).map { note($0.text, limit: nil) }.reduce(0, +)
                let between = CGFloat(replies.count) * (2 * Self.spacing + 0.5)
                return (2 * Self.padding + notes + between + (!start.isDone ? Self.spacing + Self.composer : 0)).rounded(.up)
            }
            return (2 * Self.padding + note(start.text, limit: 3) + (replies.isEmpty ? 0 : Self.spacing + Self.answeredRow)).rounded(.up)
        }

        // MARK: Ink

        /// A thread from a pin to its card: leaving the pin level, toward the card, and coming
        /// into it square to its edge, sagging by `sag`.
        public static func thread(from p: CGPoint, to a: CGPoint, sag: CGFloat) -> FlowCurve {
            let dx = a.x - p.x
            let dir: CGFloat = dx >= 0 ? 1 : -1
            let k = max(abs(dx) * 0.5, 18)
            return FlowCurve(p0: p, c1: CGPoint(x: p.x + dir * k, y: p.y + sag), c2: CGPoint(x: a.x - dir * k * 0.7, y: a.y + sag), p3: a)
        }

        /// The hand loop round a part: its points, and how wide the line is at each.
        public static func loop(around r: CGRect, seed: UInt64) -> [(CGPoint, CGFloat)] {
            let points = NoteLoop.points(seed: seed, around: r)
            return points.enumerated().map { i, p in
                let f = Double(i) / Double(max(points.count - 1, 1))
                return (p, 2.1 * CGFloat(0.3 + 0.7 * pow(sin(Double.pi * min(max(f, 0), 1)), 0.55)))
            }
        }

        public static func seed(_ id: UUID) -> UInt64 { NoteLoop.seed(id) }

        public static func ease(_ t: Double) -> Double {
            let t = min(max(t, 0), 1)
            return t * t * (3 - 2 * t)
        }

        /// Quick to start and slowing into place: a cubic ease out.
        public static func out(_ t: Double) -> Double {
            let t = min(max(t, 0), 1)
            return 1 - pow(1 - t, 3)
        }
    }

    // MARK: - Motion (the Mac's NoteMotion)

    /// What moves the margin: a spring for each card toward where it goes, so a card makes way
    /// with weight, a spring carrying a pulled pin, a loose one for each thread's sag, and the
    /// clock for threads being written in and ticked off.
    @MainActor final class NoteMotion {
        private var bodies: [UUID: Body] = [:]
        private var ghosts: [Ghost] = []
        private var view: (zoom: CGFloat, pan: CGPoint)?
        private var last: Double = 0
        private var seeded = false
        private(set) var moving = false

        static let writeIn = 0.62
        /// A card folding to a flag, or a flag unfolding to a card, in place.
        static let turn = 0.34
        static let tickOff = 0.95
        static let fade = 0.34
        /// The springs a card moves by: critically damped, so it goes straight where it is going
        /// and stops there, never past.
        static let stiffness: Double = 300
        static let damping: Double = 2 * stiffness.squareRoot()

        var idle: Bool { bodies.isEmpty && ghosts.isEmpty }
        var kinds: [UUID: NotePlacement.Kind] { bodies.mapValues(\.kind) }

        private struct Body {
            var target: CGRect
            var kind: NotePlacement.Kind
            var side: NotePlacement.Side
            var offset = FlowSpring(at: .zero)
            var pin: FlowSpring?
            var sag: CGFloat = 0
            var sagSpeed: CGFloat = 0
            var born: Double?
            var turned = false
            var done: Bool
            var last: NotesHand.Shown?
        }

        private struct Ghost {
            enum Kind { case tickedOff, gone, turned }
            var shown: NotesHand.Shown
            var since: Double
            var kind: Kind
            var lasts: Double {
                switch kind {
                case .tickedOff: NoteMotion.tickOff
                case .gone: NoteMotion.fade
                case .turned: NoteMotion.turn * 0.75
                }
            }
        }

        /// Cards and lifted cards are one shape; a flag another; a token on the table a third.
        private static func shape(_ kind: NotePlacement.Kind) -> Int {
            switch kind {
            case .card, .lifted: 0
            case .flag: 1
            case .pin: 2
            }
        }

        /// A thread let go of on something: it pulls taut, with a shiver.
        func caught(_ id: UUID) {
            bodies[id]?.sagSpeed -= 210
            moving = true
        }

        func settle(_ places: [NotePlacement.Place], _ items: [UUID: (item: NotesHand.Item, spot: CGPoint, area: CGRect?)],
                    drag: NotesHand.Drag?, pointed: UUID?, view vp: (zoom: CGFloat, pan: CGPoint), circle: CGRect?, done: Set<UUID>,
                    now: Double) -> NotesHand.Scene {
            let dt = moving ? min(max(now - last, 0), 1.0 / 30) : 0
            last = now
            // The view moving carries everything with it: nothing springs for that.
            let panned = view.map { $0.zoom != vp.zoom || $0.pan != vp.pan } ?? true
            view = vp
            var still = true
            var shown: [NotesHand.Shown] = []
            var present = Set<UUID>()
            for place in places {
                guard let entry = items[place.id] else { continue }
                let (item, spot, area) = (entry.item, entry.spot, entry.area)
                present.insert(place.id)
                var b = bodies[place.id] ?? Body(target: place.frame, kind: place.kind, side: place.side, born: seeded ? now : nil, done: item.done)
                if bodies[place.id] != nil {
                    if item.done != b.done {
                        // Ticked off where it shows (the note tool out), or brought back: written in again.
                        if item.done, let last = b.last { ghosts.append(Ghost(shown: last, since: now, kind: .tickedOff)) }
                        b.offset = FlowSpring(at: .zero)
                        b.born = now
                        b.turned = false
                        b.done = item.done
                    } else if Self.shape(b.kind) != Self.shape(place.kind) || (b.side != place.side && Self.shape(place.kind) == 0) {
                        // Folding to a flag or unfolding to a card, or a card going to the sheet's
                        // other side: never sliding across the work and its pins.
                        if let last = b.last { ghosts.append(Ghost(shown: last, since: now, kind: .turned)) }
                        b.offset = FlowSpring(at: .zero)
                        b.born = now
                        b.turned = true
                    } else if !panned {
                        let dx = b.target.minX - place.frame.minX, dy = b.target.minY - place.frame.minY
                        if abs(dx) > 0.5 || abs(dy) > 0.5 {
                            b.offset.at.x += dx
                            b.offset.at.y += dy
                            // The thread gives a little as its card goes.
                            b.sagSpeed += min(hypot(dx, dy), 60) * 0.25
                        }
                    }
                }
                b.target = place.frame
                b.kind = place.kind
                b.side = place.side
                b.offset.step(toward: .zero, dt: dt, stiffness: Self.stiffness, damping: Self.damping)
                if hypot(b.offset.at.x, b.offset.at.y) < 0.3, b.offset.resting { b.offset = FlowSpring(at: .zero) } else { still = false }

                // The pin: on its spot, or the loop's edge toward the card; pulled, carried by a spring.
                let right = place.side == .right
                var pin = area.map { NoteLoop.pin(seed: NoteLoop.seed(place.id), around: $0, right: right) } ?? spot
                var shownArea = area
                let dragged = drag?.id == place.id
                if dragged || b.pin != nil {
                    let from = drag.map { CGPoint(x: pin.x - $0.by.width, y: pin.y - $0.by.height) } ?? pin
                    var spring = b.pin ?? FlowSpring(at: dragged ? from : pin)
                    spring.step(toward: pin, dt: dt, stiffness: 620, damping: 40)
                    let d = CGSize(width: spring.at.x - pin.x, height: spring.at.y - pin.y)
                    if !dragged, spring.resting, hypot(d.width, d.height) < 0.3 {
                        b.pin = nil
                    } else {
                        b.pin = spring
                        still = false
                        pin = spring.at
                        shownArea = shownArea?.offsetBy(dx: d.width, dy: d.height)
                    }
                }
                let offset = b.offset.at
                var frame = place.frame.offsetBy(dx: offset.x, dy: offset.y)
                var anchor = CGPoint(x: place.anchor.x + offset.x, y: place.anchor.y + offset.y)
                // Whatever its springs are doing, a card never comes over its own pin.
                if Self.shape(place.kind) == 0, frame.minY < pin.y + NotePlacement.pinRoom, frame.maxY > pin.y - NotePlacement.pinRoom {
                    let dx = place.side == .right ? max(pin.x + NotePlacement.pinRoom - frame.minX, 0)
                                                  : min(pin.x - NotePlacement.pinRoom - frame.maxX, 0)
                    frame.origin.x += dx
                    anchor.x += dx
                }
                // Slack while pulled, so it hangs as a thread between two hands; a loose spring,
                // so it swings a little before it hangs still.
                let want: CGFloat = dragged ? min(hypot(anchor.x - pin.x, anchor.y - pin.y) * 0.14, 42) : 0
                var left = dt
                while left > 0 {
                    let h = min(left, 1.0 / 240)
                    b.sagSpeed += (170 * (want - b.sag) - 7.5 * b.sagSpeed) * CGFloat(h)
                    b.sag += b.sagSpeed * CGFloat(h)
                    left -= h
                }
                if abs(b.sag - want) < 0.2, abs(b.sagSpeed) < 2 { b.sag = want; b.sagSpeed = 0 } else { still = false }
                if dragged { still = false }

                var born = 1.0
                if let t = b.born {
                    born = (now - t) / (b.turned ? Self.turn : Self.writeIn)
                    if born >= 1 { b.born = nil; b.turned = false; born = 1 } else { still = false }
                }
                var s = NotesHand.Shown(id: place.id, key: place.id.uuidString, item: item, place: place, frame: frame, anchor: anchor,
                                        pin: pin, area: shownArea, sag: b.sag, born: born, leaving: nil, tickedOff: false,
                                        lit: item.open || pointed == place.id || dragged, dragged: dragged)
                s.turned = b.turned
                b.last = s
                bodies[place.id] = b
                shown.append(s)
            }
            // What has gone leaves as it goes: ticked off, or simply taken away.
            for (id, b) in bodies where !present.contains(id) {
                if let last = b.last { ghosts.append(Ghost(shown: last, since: now, kind: done.contains(id) && !b.done ? .tickedOff : .gone)) }
                bodies[id] = nil
            }
            ghosts.removeAll { now - $0.since >= $0.lasts }
            let leaving = ghosts.map { g -> NotesHand.Shown in
                var s = g.shown
                s.key = "\(s.id.uuidString)~\(g.since)"
                s.leaving = min((now - g.since) / g.lasts, 1)
                s.tickedOff = g.kind == .tickedOff
                s.turned = g.kind == .turned
                s.lit = false
                s.dragged = false
                return s
            }
            if !ghosts.isEmpty { still = false }
            seeded = true
            moving = !still
            return NotesHand.Scene(shown: shown, ghosts: leaving, circle: circle)
        }
    }
}

extension WindowsCore {
    /// How wide a note's card is, and how far down it its thread comes in.
    public static var noteCardWidth: Double { Double(NotePlacement.width) }
    public static var noteLineIn: Double { Double(NotePlacement.lineIn) }
}

extension WindowsCore {
    /// The artboard at a canvas point, by its id.
    public static func boardID(at p: CGPoint) -> UUID? { design?.artboard(at: p)?.id }
}

extension WindowsCore {
    /// Where the open design is kept, as a path.
    public static var designPath: String? { designURL?.path }
}
