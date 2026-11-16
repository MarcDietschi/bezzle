import Foundation

// MARK: - Versions

extension WindowsCore {
    /// A version of the open design, as the ruler shows it.
    nonisolated public struct Version: Sendable, Equatable {
        public let id: UUID
        public let date: Date
        public let name: String?
        /// Whose it is, when someone sharing the design named it.
        public let replica: String?
        public let shared: Bool
        public var isNamed: Bool { name != nil }

        init(_ v: DesignVersion) {
            id = v.id
            date = v.date
            name = v.name
            replica = v.replica
            shared = v.shared == true
        }
    }

    /// The versions of the design the core works on: each open design has its own (`Slot`).
    public internal(set) static var versions = Versions()

    /// Whether the canvas shows a version, or a moment of the glide to or from one, in place of
    /// the design as it is (`previewBase`).
    nonisolated(unsafe) static var showingVersion = false

    /// Shows `doc` on the canvas in place of the design as it is, kept where it is looked at;
    /// nil shows the design again.
    static func showVersion(_ doc: BezzleDocument?) {
        guard let doc else {
            guard showingVersion else { return }
            showingVersion = false
            if let base = previewBase { design = base; previewBase = nil }
            return
        }
        guard let base = previewBase ?? design else { return }
        previewBase = base
        var shown = doc
        shown.viewport = base.viewport
        design = shown
        showingVersion = true
    }

    /// The design is about to be changed here: looking back gives way to it, so the change is
    /// made to the design as it is and seen as it is made, and any change shown is taken away.
    static func beginChange() {
        versions.cameBack()
        timeTable.stop()
        endPreview()
    }

    /// The versions of an open design, as the Mac's VersionShelf keeps them: in its package's
    /// `versions` folder, a list (`index.json`) and each one packed small (`VersionKeeping`), so
    /// they go with the design between computers. Taken by themselves as it is worked on (the
    /// first save, then after ten minutes of work if it changed, and on closing if it changed),
    /// thinned as Time Machine thins, or named and kept for good. Looking back shows one on the
    /// canvas; going back is a change like any other, which can be undone, and the design as it
    /// was just before is kept as a version first.
    @MainActor public final class Versions {
        /// Oldest first.
        private var all: [DesignVersion] = []
        /// As they are kept, for sharing them.
        var kept: [DesignVersion] { all }
        public var list: [Version] { all.map(Version.init) }
        /// Whether the time ruler is out.
        public private(set) var browsing = false
        /// Looking back, at a version shown on the canvas in place of the design as it is now.
        var travel: VersionTravel?
        /// Playing the design's story: every version in turn, from the first to now.
        public private(set) var playing = false
        /// The layers last brought back, and when (`WindowsCore.now`), for the canvas to mark them.
        public private(set) var broughtBack: (ids: [UUID], at: Double)?
        /// Something the ruler or the canvas shows changed.
        public var changed: () -> Void = {}
        /// The design changed by going back or bringing back: a step to draw, save and show.
        public var edited: () -> Void = {}

        private var loaded: URL?
        private var cache: [UUID: BezzleDocument] = [:]
        /// The newest version taken here and the design as it kept it, to tell whether the design
        /// changed since without reading it back.
        private var newest: (id: UUID, doc: BezzleDocument)?
        private var player: Task<Void, Never>?
        /// What the time is, for trying an hour or a day of work.
        public var clock: () -> Date = { Date() }
        /// How long a design is worked on before a version is taken by itself.
        static let every: TimeInterval = 10 * 60

        init() {}

        /// The design opened or closed: nothing is known of its versions yet.
        func reset() {
            stop()
            all = []
            browsing = false
            travel = nil
            broughtBack = nil
            loaded = nil
            cache = [:]
            newest = nil
        }

        /// Where they are kept: the design's package. In one shared through its folder, each
        /// computer keeps a list of its own (`FolderShare.versions`), as the Mac's VersionFiles do.
        private var url: URL? {
            guard let url = WindowsCore.designURL else { return nil }
            var isFolder: ObjCBool = false
            return FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder) && isFolder.boolValue ? url : nil
        }

        private func folder(_ url: URL) -> URL { url.appendingPathComponent(FolderShare.versionsFolder, isDirectory: true) }
        private func file(_ id: UUID, _ url: URL) -> URL { FolderShare.versionFile(id, of: url) }

        /// Reads the versions kept with the design, once. One whose file is missing, as when its
        /// copy never arrived, is left out: there would be nothing to show for it.
        public func load() {
            guard let url, loaded != url else { return }
            loaded = url
            all = FolderShare.versions(of: url, replica: WindowsCore.replica).filter {
                FileManager.default.fileExists(atPath: file($0.id, url).path) || FileManager.default.fileExists(atPath: WindowsCore.arrivals.version($0.id, of: url).path)
            }
        }

        private func makeRoom() -> URL? {
            // A design kept as a single file becomes a package, where versions have room.
            guard (try? WindowsCore.makePackage()) != nil else { return nil }
            load()
            return url
        }

        /// The design as it is, not as the canvas may be showing it.
        private var present: BezzleDocument? { WindowsCore.previewBase ?? WindowsCore.design }

        /// The design was just saved: a version is taken if there is none yet, or the newest is
        /// old enough and the design has changed since; at once on closing, if it changed at all.
        public func saved(closing: Bool = false) {
            guard travel == nil, !WindowsCore.isReadOnly, let doc = present, makeRoom() != nil else { return }
            if let last = all.last {
                guard closing || clock().timeIntervalSince(last.date) >= Self.every else { return }
                guard differs(doc, from: last) else { return }
            }
            take(doc, name: nil)
        }

        private func differs(_ doc: BezzleDocument, from last: DesignVersion) -> Bool {
            let known = newest?.id == last.id ? newest?.doc : document(last.id)
            guard var b = known else { return true }
            var a = doc
            a.viewport = nil
            b.viewport = nil
            return a != b
        }

        /// Keeps the design as it is now as a version, named or not.
        @discardableResult
        func take(_ doc: BezzleDocument, name: String?) -> DesignVersion? {
            guard let url = makeRoom() else { return nil }
            let author = WindowsCore.noteAuthor
            var version = DesignVersion(date: clock(), name: name, by: author.name, replica: author.replica, layers: doc.layerCount)
            // Named in a shared design, it is everyone's.
            if name != nil, WindowsCore.sharing != nil { version.shared = true }
            let keep = VersionKeeping.kept(all + [version], now: clock())
            let dropped = (all + [version]).filter { v in !keep.contains { $0.id == v.id } }.map(\.id)
            all = keep
            var bare = doc
            bare.viewport = nil
            newest = (version.id, bare)
            cache[version.id] = bare
            for id in dropped { cache[id] = nil }
            do {
                guard let data = VersionKeeping.pack(bare) else { return version }
                try WindowsCore.makeFolder(folder(url), in: url)
                try data.write(to: file(version.id, url), options: .atomic)
                try writeIndex(url)
                for id in dropped { try? FileManager.default.removeItem(at: file(id, url)) }
                // Named in a design shared by link, it goes to the room for everyone.
                if version.shared == true { WindowsCore.sharing?.cloud?.sendVersion(version, data: data) }
            } catch {
                NSLog("Bezzle could not keep a version of %@: %@", url.path, "\(error)")
            }
            changed()
            return version
        }

        /// This computer's list: in a design shared through its folder, in its own folder of files there.
        private func writeIndex(_ url: URL) throws {
            let index = FolderShare.versionIndex(of: url, replica: WindowsCore.replica)
            try WindowsCore.makeFolder(index.deletingLastPathComponent(), in: url)
            try VersionKeeping.data(of: all).write(to: index, options: .atomic)
        }

        /// A named version someone sharing the design kept, from its folder or the live room.
        func arrived(_ version: DesignVersion, data: Data) {
            guard let url else { return }
            load()
            var version = version
            version.shared = true
            if let i = all.firstIndex(where: { $0.id == version.id }) {
                // Renamed elsewhere.
                guard all[i].name != version.name else { return }
                all[i].name = version.name
            } else {
                guard let doc = VersionKeeping.unpack(data) else { return }
                all = (all + [version]).sorted { $0.date < $1.date }
                cache[version.id] = doc
            }
            // In a synced folder whoever named it writes it into the design, and this computer's list
            // goes with its next change of its own: it waits beside the design meanwhile.
            if WindowsCore.inSyncedFolder {
                if !FileManager.default.fileExists(atPath: file(version.id, url).path) {
                    try? WindowsCore.arrivals.keep(data, as: "\(version.id.uuidString).lzfse", in: WindowsCore.arrivals.versions(of: url))
                }
                changed()
                return
            }
            if !FileManager.default.fileExists(atPath: file(version.id, url).path) {
                try? WindowsCore.makeFolder(folder(url), in: url)
                try? data.write(to: file(version.id, url), options: .atomic)
            }
            try? writeIndex(url)
            changed()
        }

        /// Gives the design as it is now a name, as a version kept for good.
        public func nameNow(_ name: String) {
            guard let doc = present else { return }
            let words = name.trimmingCharacters(in: .whitespacesAndNewlines)
            take(doc, name: words.isEmpty ? String(localized: "Named version") : words)
        }

        /// Names a version already kept, or renames it; without a name it is one among the others
        /// again, thinned away in time as they are.
        public func rename(_ id: UUID, _ name: String) {
            guard let url, let i = all.firstIndex(where: { $0.id == id }) else { return }
            let words = name.trimmingCharacters(in: .whitespacesAndNewlines)
            let named = words.isEmpty ? nil : words
            guard all[i].name != named else { return }
            all[i].name = named
            if WindowsCore.sharing != nil, named != nil { all[i].shared = true }
            try? writeIndex(url)
            if all[i].shared == true, let data = try? Data(contentsOf: file(id, url)) { WindowsCore.sharing?.cloud?.sendVersion(all[i], data: data) }
            changed()
        }

        func document(_ id: UUID) -> BezzleDocument? {
            if let doc = cache[id] { return doc }
            // One someone else named may still wait beside a design in a synced folder (`WindowsCore.arrivals`).
            guard let url, let data = (try? Data(contentsOf: file(id, url))) ?? (try? Data(contentsOf: WindowsCore.arrivals.version(id, of: url))),
                  let doc = VersionKeeping.unpack(data) else { return nil }
            cache[id] = doc
            return doc
        }

        // MARK: Looking back

        /// The version shown, if one is.
        public var shown: Version? { travel.flatMap { t in all.first { $0.id == t.at } }.map(Version.init) }
        /// Where the version shown stands in the list; the list's count when it is now.
        public var shownIndex: Int { travel.flatMap { t in all.firstIndex { $0.id == t.at } } ?? all.count }
        /// How many layers are picked to bring back.
        public var pickedCount: Int { travel?.picked.count ?? 0 }
        public var lookingBack: Bool { travel != nil }

        /// Brings the time ruler out, at the design as it is now.
        public func browse() {
            load()
            browsing = true
            changed()
        }

        /// Shows a version on the canvas.
        public func show(_ id: UUID) {
            stop()
            go(to: id)
        }

        private func go(to id: UUID) {
            guard let past = document(id), let now = present else { return }
            if travel?.at == id { return }
            browsing = true
            travel = VersionTravel(at: id, doc: past, now: now)
            WindowsCore.timeTable.aim(at: past)
            changed()
        }

        /// Back to the design as it is now, the ruler staying out.
        public func showNow() {
            stop()
            comeBack()
        }

        private func comeBack() {
            guard travel != nil else { return }
            travel = nil
            WindowsCore.timeTable.aim(at: nil)
            changed()
        }

        /// Puts the ruler away, back at the design as it is now.
        public func leave() {
            showNow()
            browsing = false
            changed()
        }

        /// The design is about to be changed here: looking back gives way to it at once.
        func cameBack() {
            guard travel != nil || playing else { return }
            stop()
            travel = nil
            WindowsCore.timeTable.stop()
            changed()
        }

        /// The design changed while looking back (by someone else): what is marked as differing
        /// is worked out again.
        public func presentChanged() {
            guard var t = travel, let now = present else { return }
            t.compare(with: now)
            if t != travel { travel = t; changed() }
        }

        /// The version before or after the one shown; after the newest, now.
        public func step(_ by: Int) {
            stop()
            load()
            let j = min(max(shownIndex + by, 0), all.count)
            if j >= all.count { comeBack() } else { go(to: all[j].id) }
        }

        /// Shows the version at `index` in the list, or now at its end.
        public func show(index: Int) {
            if index >= all.count { showNow() } else if index >= 0 { show(all[index].id) }
        }

        // MARK: The story

        /// Plays the design's story: from its first version through each one after to now.
        public func play() {
            load()
            guard !all.isEmpty else { return }
            stop()
            browsing = true
            playing = true
            let steps = VersionKeeping.story(of: all)
            let beat = min(max(10 / Double(steps.count + 1), 0.34), 0.85)
            go(to: steps[0])
            changed()
            player = Task { @MainActor [weak self] in
                for id in steps.dropFirst() {
                    try? await Task.sleep(nanoseconds: UInt64(beat * 1e9))
                    guard let self, !Task.isCancelled else { return }
                    self.go(to: id)
                }
                try? await Task.sleep(nanoseconds: UInt64(beat * 1e9))
                guard let self, !Task.isCancelled else { return }
                self.comeBack()
                self.playing = false
                self.player = nil
                self.changed()
            }
        }

        /// Stops playing the story, where it is.
        public func stop() {
            player?.cancel()
            player = nil
            if playing { playing = false; changed() }
        }

        // MARK: Going back

        /// A click on the canvas while looking back picks a layer that differs, to bring back alone.
        public func pick(at p: CGPoint) {
            guard var t = travel else { return }
            t.pick(at: p)
            if t != travel { travel = t; changed() }
        }

        /// The layer that differs from now under a canvas point, as the design was then.
        public func layer(at p: CGPoint) -> UUID? { travel?.layer(at: p) }

        /// Goes back to the version shown: the design becomes what it was then, its notes staying
        /// as they are now. What it is now is kept as a named version first.
        public func restore() {
            guard let t = travel else { return }
            restore(t.at)
        }

        public func restore(_ id: UUID) {
            guard let version = all.first(where: { $0.id == id }), let past = document(id) else { return }
            showNow()
            guard let now = present, !past.sameDesign(as: now) else { return }
            let when = version.name ?? version.date.formatted(date: .abbreviated, time: .shortened)
            take(now, name: String(localized: "Before going back to \(when)"))
            WindowsCore.edit { $0.goBack(to: past) }
            edited()
        }

        /// Brings the picked layers back as they were, into the design as it is now.
        public func bringBack() -> [UUID] {
            guard let t = travel, !t.picked.isEmpty else { return [] }
            let past = t.doc, ids = t.picked
            showNow()
            WindowsCore.edit { $0.bringBack(ids, from: past) }
            let there = ids.filter { WindowsCore.design?.node($0) != nil }.sorted { $0.uuidString < $1.uuidString }
            broughtBack = (there, WindowsCore.now)
            edited()
            // The canvas marks them landing.
            changed()
            return there
        }

        public func dropPicked() {
            guard travel?.picked.isEmpty == false else { return }
            travel?.picked = []
            changed()
        }

        // MARK: What the canvas marks

        /// A layer that differs from now, as the design was then: changed or gone, picked or not.
        nonisolated public struct Mark: Sendable {
            public let id: UUID
            public let frame: CGRect
            public let gone: Bool
            public let picked: Bool
            /// Where it is now, if it is still there.
            public let now: CGRect?
        }

        /// What differs from now, the outer one standing for what it holds; artboards that only
        /// changed are not marked.
        public func marks() -> [Mark] {
            guard let t = travel else { return [] }
            let present = self.present
            return t.changed.union(t.gone).compactMap { id in
                guard let frame = t.doc.absoluteFrame(of: id) else { return nil }
                if t.doc.ancestors(of: id).contains(where: { (t.changed.contains($0.id) || t.gone.contains($0.id)) && !$0.isArtboard }) { return nil }
                if t.doc.node(id)?.isArtboard == true, t.changed.contains(id) { return nil }
                return Mark(id: id, frame: frame, gone: t.gone.contains(id), picked: t.picked.contains(id),
                            now: t.gone.contains(id) ? nil : present?.absoluteFrame(of: id))
            }.sorted { $0.id.uuidString < $1.id.uuidString }
        }

        /// Where the layers made since will be, faintly: not those inside others made since, nor
        /// artboards.
        public func madeSince() -> [CGRect] {
            guard let t = travel, let present else { return [] }
            return t.added.compactMap { id in
                guard !present.ancestors(of: id).contains(where: { t.added.contains($0.id) }), present.node(id)?.isArtboard == false else { return nil }
                return present.absoluteFrame(of: id)
            }
        }

        /// Where the layers last brought back are, while their landing is marked.
        public func landing() -> (frames: [CGRect], age: Double)? {
            guard let b = broughtBack else { return nil }
            let age = (WindowsCore.now - b.at) / TimeTable.slow
            guard age < 1.1 else { return nil }
            return (b.ids.compactMap { present?.absoluteFrame(of: $0) }, age)
        }
    }

    // MARK: - The glide

    /// The canvas showing what it is looking back at, as the Mac's TimeTable does: going from one
    /// version to another, the layers glide together to how they were, those not made yet fade
    /// away, and those taken away since come back.
    public internal(set) static var timeTable = TimeTable()

    @MainActor public final class TimeTable {
        private struct Glide {
            var began: Double
            /// Those changing, as they were drawn as it began, outer ones first.
            var from: [(UUID, Node)]
            var appearing: [UUID]
            var vanishing: [(node: Node, parent: UUID?, index: Int)]
        }

        private var glide: Glide?
        /// The design shown when the glide is done: a version, or nil for the design as it is.
        private var target: BezzleDocument?
        /// The design last drawn.
        private var drawn: BezzleDocument?
        /// The top layers the canvas shows, to tell it which to draw again.
        private var shownNodes: [Node]?
        /// How long the layers take to get there, and the marks after.
        public static let duration = 0.42
        public static let marking = 0.3
        /// For looking at the motion frame by frame: `BEZZLE_SLOW=8` plays it eight times slower.
        static let slow: Double = ProcessInfo.processInfo.environment["BEZZLE_SLOW"].flatMap(Double.init).map { max($0, 1) } ?? 1

        init() {}

        /// Starts gliding from what is drawn to `doc`, or to the design as it is.
        func aim(at doc: BezzleDocument?) {
            let to = doc ?? (WindowsCore.previewBase ?? WindowsCore.design)
            // From what the canvas shows: a version or a moment of a glide, or the design as it is.
            if let from = WindowsCore.showingVersion ? (drawn ?? WindowsCore.design) : WindowsCore.design, let to {
                begin(from: from, to: to)
            }
            // What the canvas shows now: the design as it is, unless a version is up already.
            if !WindowsCore.showingVersion || shownNodes == nil { shownNodes = WindowsCore.design?.nodes }
            target = doc
            pending = merge(pending, frame(at: WindowsCore.now))
        }

        /// What the last frames changed that the canvas has not drawn yet.
        private var pending: [Int]?

        /// What changed since the canvas last asked: nil nothing, empty everything, else the top
        /// layers by index.
        public func changes() -> [Int]? {
            defer { pending = nil }
            return pending
        }

        private func merge(_ a: [Int]?, _ b: [Int]?) -> [Int]? {
            guard let a else { return b }
            guard let b else { return a }
            if a.isEmpty || b.isEmpty { return [] }
            return Array(Set(a).union(b)).sorted()
        }

        private func changed(to doc: BezzleDocument?) -> [Int]? {
            let now = doc?.nodes ?? []
            defer { shownNodes = now }
            guard let was = shownNodes, was.count == now.count else { return [] }
            let k = now.indices.filter { was[$0] != now[$0] }
            return k.isEmpty ? nil : k
        }

        /// Shows again what is looked back at, should a change pointed at have taken its place.
        func reshow() {
            guard let shown = drawn ?? target else { return }
            WindowsCore.showVersion(shown)
            pending = merge(pending, changed(to: WindowsCore.design))
        }

        /// The design opened or closed: nothing drawn yet.
        func forget() {
            glide = nil
            target = nil
            drawn = nil
            shownNodes = nil
            pending = nil
        }

        /// Looking back given up for a change: the design as it is, at once.
        func stop() {
            let showing = WindowsCore.showingVersion
            glide = nil
            target = nil
            drawn = nil
            WindowsCore.showVersion(nil)
            if showing { pending = merge(pending, changed(to: WindowsCore.design)) }
        }

        private func begin(from: BezzleDocument, to: BezzleDocument) {
            let d = VersionKeeping.differences(from, to)
            var changing: [(UUID, Node, Int)] = []
            for id in d.changed {
                guard let n = from.node(id) else { continue }
                changing.append((id, n, from.path(of: id)?.indices.count ?? 0))
            }
            let appearing = d.added.filter { id in !to.ancestors(of: id).contains { d.added.contains($0.id) } }
            var vanishing: [(node: Node, parent: UUID?, index: Int)] = []
            for id in d.gone where !from.ancestors(of: id).contains(where: { d.gone.contains($0.id) }) {
                guard let n = from.node(id), let path = from.path(of: id) else { continue }
                vanishing.append((n, from.parent(of: id)?.id, path.indices.last ?? 0))
            }
            vanishing.sort { $0.index < $1.index }
            glide = Glide(began: WindowsCore.now, from: changing.sorted { $0.2 < $1.2 }.map { ($0.0, $0.1) },
                          appearing: Array(appearing), vanishing: vanishing)
        }

        /// Whether the layers are on their way, or the marks still being drawn.
        public var moving: Bool { glide != nil }

        /// How far the marks are drawn, 0 to 1, once the layers have got there.
        public var inked: Double {
            guard let g = glide else { return 1 }
            return min(max(((WindowsCore.now - g.began) / Self.slow - Self.duration * 0.7) / Self.marking, 0), 1)
        }

        /// Shows the moment `now` of the glide on the canvas, and says which top layers it changed:
        /// nil none, empty all, else their indices.
        public func frame(at now: Double) -> [Int]? {
            let shown = target ?? (WindowsCore.previewBase ?? WindowsCore.design)
            guard let shown else { return nil }
            guard let g = glide else {
                finish(shown)
                return changed(to: WindowsCore.design)
            }
            let t = (now - g.began) / Self.slow / Self.duration
            if t >= 1 {
                if (now - g.began) / Self.slow > Self.duration + Self.marking { glide = nil }
                finish(shown)
                return changed(to: WindowsCore.design)
            }
            let e = t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2
            var out = shown
            for (id, from) in g.from where out.node(id) != nil {
                out.update(id) { $0 = from.blended(to: $0, e) }
            }
            for id in g.appearing {
                out.update(id) { $0.opacity *= e }
            }
            for v in g.vanishing where out.node(v.node.id) == nil {
                var node = v.node
                node.opacity *= 1 - e
                if let parent = v.parent {
                    guard let path = out.path(of: parent) else { continue }
                    out.insert(node, at: NodePath(indices: path.indices + [min(v.index, out.node(parent)?.children.count ?? 0)]))
                } else {
                    out.insert(node, at: NodePath(indices: [min(v.index, out.nodes.count)]))
                }
            }
            drawn = out
            WindowsCore.showVersion(out)
            return changed(to: WindowsCore.design)
        }

        private func finish(_ shown: BezzleDocument) {
            drawn = shown
            if target != nil { WindowsCore.showVersion(shown) } else { WindowsCore.showVersion(nil) }
        }
    }
}

// MARK: - The ruler

extension WindowsCore {
    /// The comb's motion on the ruler of time (the shared RulerMotion): each stroke's height on a
    /// spring, swelling under the pointer and plucked as the pencil line passes it; the line, and
    /// the label gliding with the pointer.
    @MainActor public final class Comb {
        private let motion = RulerMotion()

        public init() {}

        public func step(at now: Date, xs: [Double], bases: [Double], pointer: Double?, head: Double, held: Bool, width: Double) {
            motion.step(at: now, xs: xs, bases: bases, pointer: pointer, head: head, held: held, width: width)
        }

        public var heights: [Double] { motion.heights.map(\.value) }
        public var glow: [Double] { motion.glow }
        public var head: Double { motion.head.value }
        public var lift: Double { motion.lift.value }
        public var lens: Double { motion.lens.value }
        public var lensShown: Double { motion.lensShown.value }
        public var wave: [Double] { motion.wave }
        public func swell(at x: Double) -> Double { motion.swell(at: x) }
        public func ripple(at x: Double) -> Double { motion.ripple(at: x) }
        public static var spacing: Double { RulerMotion.spacing }
        public var settled: Bool { motion.settled }
    }

    /// Where each version stands along a comb this wide, and now after the last.
    public static func slots(_ dates: [Date], width: Double, now: Date = Date()) -> [Double] {
        VersionKeeping.slots(dates, width: width, now: now)
    }

    public static func nearestSlot(_ x: Double, in xs: [Double]) -> Int {
        VersionKeeping.nearest(x, in: xs)
    }

    /// The colour of the sky at a moment: blue by day, gold and rose as the sun goes down,
    /// indigo by night.
    public static func sky(at date: Date) -> (r: Double, g: Double, b: Double) {
        Sky.at(date).sky
    }
}
