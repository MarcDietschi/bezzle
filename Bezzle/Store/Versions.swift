import Foundation
import Observation

// MARK: - Versions

/// A design as it was at one moment, kept to look back at and to go back to. Some are taken by
/// themselves as a design is worked on; some are given a name, and those are kept for good and,
/// in a shared design, shared with everyone.
nonisolated struct DesignVersion: Codable, Identifiable, Hashable, Sendable {
    var id = UUID()
    var date: Date
    /// A name given it; a version with one is kept for good.
    var name: String?
    /// Who took or named it.
    var by: String?
    var replica: String?
    /// How many layers the design had.
    var layers = 0
    /// Named in a shared design, and so kept by everyone it is shared with.
    var shared: Bool?

    var isNamed: Bool { name != nil }
}

/// Where a design keeps its versions: a folder in its package, with a list of them and each
/// one packed small. Pictures never change once in a design, so a version only needs the design
/// itself to be whole.
///
/// In a design shared through a synced folder, each Mac keeps its list in its own folder there
/// (see `FolderShare`), as two writing one list would lose one's; the versions themselves, each
/// a file of its own, never written over, stay where they are. Each Mac sees its own and the
/// versions everyone named.
nonisolated enum VersionFiles {
    static let folderName = "versions"

    static func folder(of design: URL) -> URL { design.appendingPathComponent(folderName, isDirectory: true) }
    private static func indexFile(_ design: URL) -> URL { folder(of: design).appendingPathComponent("index.json") }
    static func file(_ id: UUID, of design: URL) -> URL { folder(of: design).appendingPathComponent("\(id.uuidString).lzfse") }

    /// The list a Mac with `replica` keeps of a design shared through its folder.
    private static func ownIndexFile(_ design: URL, _ replica: String) -> URL {
        FolderSync.folder(of: replica, in: design).appendingPathComponent(FolderShare.versionsFile)
    }

    static func index(of design: URL, replica: String) -> [DesignVersion] {
        guard FolderSync.isShared(design) else { return list(at: indexFile(design)) }
        let fm = FileManager.default
        let mine = ownIndexFile(design, replica)
        let others = ((try? fm.contentsOfDirectory(at: FolderSync.peopleFolder(of: design), includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? [])
            .filter { $0.lastPathComponent != replica }
            .map { $0.appendingPathComponent(FolderShare.versionsFile) }
            .filter { fm.fileExists(atPath: $0.path) }
        var out = list(at: mine)
        // The design's versions from before it was shared through its folder are the first
        // Mac's to share it, to keep on as its own.
        if !fm.fileExists(atPath: mine.path), others.isEmpty { out = list(at: indexFile(design)) }
        var at: [UUID: Int] = [:]
        for (i, v) in out.enumerated() { at[v.id] = i }
        for file in others {
            for v in list(at: file) where v.isNamed && v.shared == true {
                if let i = at[v.id] {
                    // Its name as the one who took it last gave it.
                    if v.replica == file.deletingLastPathComponent().lastPathComponent { out[i].name = v.name }
                } else {
                    at[v.id] = out.count
                    out.append(v)
                }
            }
        }
        return out.sorted { $0.date < $1.date }
    }

    static func list(at file: URL) -> [DesignVersion] {
        guard let data = try? Data(contentsOf: file) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return ((try? decoder.decode([DesignVersion].self, from: data)) ?? []).sorted { $0.date < $1.date }
    }

    static func writeIndex(_ list: [DesignVersion], to design: URL, replica: String) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        let data = try encoder.encode(list)
        if FolderSync.isShared(design) {
            let file = ownIndexFile(design, replica)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: file, options: .atomic)
            return
        }
        try FileManager.default.createDirectory(at: folder(of: design), withIntermediateDirectories: true)
        try data.write(to: indexFile(design), options: .atomic)
    }

    /// The design packed as a version keeps it: without where it was looked at.
    static func pack(_ doc: BezzleDocument) -> Data? {
        var doc = doc
        doc.viewport = nil
        guard let json = try? JSONEncoder().encode(doc) else { return nil }
        return try? (json as NSData).compressed(using: .lzfse) as Data
    }

    static func unpack(_ data: Data) -> BezzleDocument? {
        guard let json = try? (data as NSData).decompressed(using: .lzfse) as Data,
              var doc = try? JSONDecoder().decode(BezzleDocument.self, from: json) else { return nil }
        doc.repairStyles()
        return doc
    }

    static func read(_ id: UUID, of design: URL) -> BezzleDocument? {
        (try? Data(contentsOf: file(id, of: design))).flatMap(unpack)
    }

    static func write(_ data: Data, as id: UUID, to design: URL) throws {
        try FileManager.default.createDirectory(at: folder(of: design), withIntermediateDirectories: true)
        try data.write(to: file(id, of: design), options: .atomic)
    }

    static func remove(_ ids: [UUID], from design: URL) {
        for id in ids { try? FileManager.default.removeItem(at: file(id, of: design)) }
    }

    /// Of the versions taken by themselves, those worth keeping, as Time Machine keeps backups:
    /// every one of the last hour, one each half hour of the last day, one a day for a month, and
    /// one a week before that. Named versions are always kept, and the newest is.
    static func kept(_ list: [DesignVersion], now: Date = Date()) -> [DesignVersion] {
        var out: [DesignVersion] = []
        var buckets = Set<String>()
        for v in list.sorted(by: { $0.date > $1.date }) {
            let age = now.timeIntervalSince(v.date)
            // The newest needs no exception: its bucket is always still free, and it claims it.
            if v.isNamed || age < 3600 { out.append(v); continue }
            let bucket: String
            if age < 86_400 { bucket = "h\(Int(v.date.timeIntervalSince1970 / 1800))" }
            else if age < 30 * 86_400 { bucket = "d\(Int(v.date.timeIntervalSince1970 / 86_400))" }
            else { bucket = "w\(Int(v.date.timeIntervalSince1970 / (7 * 86_400)))" }
            if buckets.insert(bucket).inserted { out.append(v) }
        }
        return out.sorted { $0.date < $1.date }
    }
}

// MARK: - A design's versions

/// The versions of an open design: taking them as it is worked on, naming them, looking back
/// through them on the canvas, and going back, wholly or a layer at a time. Going back is a
/// change like any other, which can be undone, and the design as it was just before is kept as
/// a version first, so nothing is ever lost by it.
@Observable
final class VersionShelf {
    /// Oldest first.
    private(set) var list: [DesignVersion] = []
    /// Whether the time ruler is out, to look back through the versions.
    private(set) var browsing = false
    /// Looking back, at a version shown on the canvas in place of the design as it is now.
    private(set) var travel: TimeTravel?
    /// Playing the design's story: every version in turn, from the first to now.
    private(set) var playing = false
    /// The layers last brought back, and when, for the canvas to mark them landing.
    @ObservationIgnored private(set) var broughtBack: (ids: [UUID], at: Date)?

    struct TimeTravel: Equatable {
        var at: UUID
        var doc: BezzleDocument
        /// Layers that differ from the design now: changed since, gone since, and made since.
        var changed: Set<UUID>
        var gone: Set<UUID>
        var added: Set<UUID> = []
        /// Layers picked on the canvas, to bring back alone.
        var picked: Set<UUID> = []
    }

    @ObservationIgnored private weak var store: DocumentStore?
    @ObservationIgnored private var loaded = false
    @ObservationIgnored private var cache: [UUID: BezzleDocument] = [:]
    /// The newest version this Mac took and the design as it kept it, to tell whether the design
    /// changed since without reading it back.
    @ObservationIgnored private var newest: (id: UUID, doc: BezzleDocument)?
    @ObservationIgnored private var player: Task<Void, Never>?
    @ObservationIgnored private var refreshing: Task<Void, Never>?
    /// What the time is. Tests set it, to see what an hour or a day of work leaves behind.
    @ObservationIgnored var clock: () -> Date = { Date() }
    /// How fast the story plays: 1 as it is shown, less for tests.
    @ObservationIgnored var tempo: Double = 1

    /// How long a design is worked on before a version is taken by itself.
    static let every: TimeInterval = 10 * 60

    func attach(_ store: DocumentStore) {
        self.store = store
    }

    private var url: URL? { store.flatMap { DesignFile.isPackage($0.url) ? $0.url : nil } }
    /// Which Mac's list of versions is this one's, in a design shared through its folder.
    private var replica: String { store?.sharing?.replica ?? Sharing.replica }

    /// Reads the versions kept with the design, once. One whose file is missing, as when its
    /// copy never arrived, is left out: there would be nothing to show for it.
    func load() {
        guard !loaded, let url else { return }
        loaded = true
        list = VersionFiles.index(of: url, replica: replica).filter { FileManager.default.fileExists(atPath: VersionFiles.file($0.id, of: url).path) }
    }

    /// A design kept as a single file becomes a package, where versions have room.
    private func makeRoom() -> URL? {
        guard let store else { return nil }
        if !DesignFile.isPackage(store.url) {
            // What is being written of it first, so it is not written over as it is turned.
            DocumentStore.finishSaving()
            guard (try? DesignFile.makePackage(store.url)) != nil else { return nil }
            store.becamePackage()
        }
        load()
        return url
    }

    /// The design was just saved: a version is taken if there is none yet, or the newest is old
    /// enough and the design has changed since; at once on closing, if it has changed at all.
    func saved(_ doc: BezzleDocument, closing: Bool = false) {
        guard let store, !store.isReadOnly, travel == nil, makeRoom() != nil else { return }
        if let last = list.last {
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

    /// Keeps the design as it is now as a version, named or not, and returns it.
    @discardableResult
    func take(_ doc: BezzleDocument, name: String?) -> DesignVersion? {
        guard let store, let url = makeRoom() else { return nil }
        let author = store.noteAuthor
        var version = DesignVersion(date: clock(), name: name, by: author.name, replica: author.replica, layers: doc.layerCount)
        if name != nil, store.sharing != nil { version.shared = true }
        var all = list + [version]
        let keep = VersionFiles.kept(all, now: clock())
        let dropped = all.filter { v in !keep.contains { $0.id == v.id } }.map(\.id)
        all = keep
        list = all
        var bare = doc
        bare.viewport = nil
        newest = (version.id, bare)
        cache[version.id] = bare
        for id in dropped { cache[id] = nil }
        // Packed away from the main thread, in turn with the design's own saves.
        let made = version, kept = all, packing = bare, replica = replica
        DocumentStore.saving.async { [weak self] in
            guard let data = VersionFiles.pack(packing) else { return }
            do {
                try VersionFiles.write(data, as: made.id, to: url)
                try VersionFiles.writeIndex(kept, to: url, replica: replica)
                VersionFiles.remove(dropped, from: url)
            } catch {
                NSLog("Bezzle could not keep a version of %@: %@", url.path, error.localizedDescription)
            }
            if made.shared == true { Task { @MainActor in self?.shareNamed(made, data: data) } }
        }
        return made
    }

    /// Gives the design as it is now a name, as a version kept for good.
    @discardableResult
    func nameNow(_ name: String) -> DesignVersion? {
        guard let store, !store.isReadOnly else { return nil }
        let words = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return take(store.sharedDoc, name: words.isEmpty ? Self.defaultName : words)
    }

    static var defaultName: String { String(localized: "Named version") }

    /// Names a version already kept, or renames it; named, it is kept for good. Without a name it
    /// is one among the others again, thinned away in time as they are.
    func rename(_ id: UUID, _ name: String) {
        guard let url, let store, !store.isReadOnly, let i = list.firstIndex(where: { $0.id == id }) else { return }
        let words = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let named = words.isEmpty ? nil : words
        guard list[i].name != named else { return }
        list[i].name = named
        if store.sharing != nil, named != nil { list[i].shared = true }
        let all = list, version = list[i], replica = replica
        // Its file may still be on its way to the disk: read once it is.
        DocumentStore.saving.async { [weak self] in
            try? VersionFiles.writeIndex(all, to: url, replica: replica)
            guard version.shared == true, let data = try? Data(contentsOf: VersionFiles.file(version.id, of: url)) else { return }
            Task { @MainActor in self?.shareNamed(version, data: data) }
        }
    }

    func document(_ id: UUID) -> BezzleDocument? {
        if let doc = cache[id] { return doc }
        guard let url, let doc = VersionFiles.read(id, of: url) else { return nil }
        cache[id] = doc
        return doc
    }

    // MARK: Shared

    private func shareNamed(_ version: DesignVersion, data: Data) {
        guard let session = store?.sharing else { return }
        session.live?.announce(version, data: data)
        session.cloud?.sendVersion(version, data: data)
    }

    /// A named version someone sharing the design kept, from the room's records, its folder or the live room.
    func arrived(_ version: DesignVersion, data: Data) {
        guard let url else { return }
        load()
        var version = version
        version.shared = true
        if let i = list.firstIndex(where: { $0.id == version.id }) {
            // Renamed elsewhere.
            guard list[i].name != version.name else { return }
            list[i].name = version.name
        } else {
            guard let doc = VersionFiles.unpack(data) else { return }
            list = (list + [version]).sorted { $0.date < $1.date }
            cache[version.id] = doc
        }
        let all = list, replica = replica
        DocumentStore.saving.async {
            if !FileManager.default.fileExists(atPath: VersionFiles.file(version.id, of: url).path) { try? VersionFiles.write(data, as: version.id, to: url) }
            try? VersionFiles.writeIndex(all, to: url, replica: replica)
        }
    }

    // MARK: Looking back

    /// The version shown, if one is.
    var shown: DesignVersion? { travel.flatMap { t in list.first { $0.id == t.at } } }

    /// Brings the time ruler out, at the design as it is now.
    func browse() {
        load()
        browsing = true
    }

    /// Shows a version on the canvas, the design gliding there from what is shown now.
    func show(_ id: UUID) {
        stop()
        go(to: id)
    }

    private func go(to id: UUID) {
        guard let store, let past = document(id) else { return }
        if travel?.at == id { return }
        browsing = true
        let d = Self.differences(past, store.sharedDoc)
        travel = TimeTravel(at: id, doc: past, changed: d.changed, gone: d.gone, added: d.added)
        store.preview = DocumentStore.Preview(key: Self.previewKey, ids: [], change: { _ in }, reshape: { doc in
            let viewport = doc.viewport
            doc = past
            doc.viewport = viewport
        })
    }

    /// What differs between a design then and now: layers changed since, not counting what they
    /// hold; gone since; and made since.
    static func differences(_ past: BezzleDocument, _ now: BezzleDocument) -> (changed: Set<UUID>, gone: Set<UUID>, added: Set<UUID>) {
        var gone = Set<UUID>(), changed = Set<UUID>()
        var mine: [UUID: Node] = [:]
        for n in now.allNodes { mine[n.id] = n }
        var seen = Set<UUID>()
        for n in past.allNodes {
            seen.insert(n.id)
            guard let m = mine[n.id] else { gone.insert(n.id); continue }
            var a = n, b = m
            a.children = []
            b.children = []
            if a != b { changed.insert(n.id) }
        }
        return (changed, gone, Set(mine.keys).subtracting(seen))
    }

    static let previewKey = "versions"

    /// Back to the design as it is now, the ruler staying out.
    func showNow() {
        stop()
        comeBack()
    }

    private func comeBack() {
        guard travel != nil else { return }
        travel = nil
        if store?.preview?.key == Self.previewKey { store?.preview = nil }
    }

    /// Puts the ruler away, back at the design as it is now.
    func leave() {
        showNow()
        browsing = false
    }

    /// The design is about to be changed here, by a menu, by undo or by the assistant: looking
    /// back gives way to it, so the change is seen as it is made.
    func cameBack() {
        guard travel != nil || playing else { return }
        showNow()
    }

    /// The design changed, maybe by someone else while looking back: what is marked as differing
    /// is worked out again, a moment later, as their changes come many to the second.
    func presentChanged() {
        guard travel != nil, refreshing == nil else { return }
        refreshing = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard let self else { return }
            self.refreshing = nil
            guard var t = self.travel, let store = self.store else { return }
            let d = Self.differences(t.doc, store.sharedDoc)
            t.changed = d.changed
            t.gone = d.gone
            t.added = d.added
            t.picked = t.picked.filter { d.changed.contains($0) || d.gone.contains($0) }
            if t != self.travel { self.travel = t }
        }
    }

    /// Shows again what is looked back at, should something else have taken the canvas's preview.
    func keepShown() {
        guard let t = travel, store?.preview?.key != Self.previewKey else { return }
        travel = nil
        go(to: t.at)
    }

    /// The version before or after the one shown; after the newest, now.
    func step(_ by: Int) {
        stop()
        load()
        let i = travel.flatMap { t in list.firstIndex { $0.id == t.at } } ?? list.count
        let j = min(max(i + by, 0), list.count)
        if j >= list.count { comeBack() } else { go(to: list[j].id) }
    }

    // MARK: The story

    /// Plays the design's story: from its first version through each one after to now, as the
    /// light of the hours it was made in passes over it. Many versions are played a choice of,
    /// the named ones always.
    func play() {
        load()
        guard !list.isEmpty else { return }
        stop()
        browsing = true
        playing = true
        let steps = Self.story(of: list)
        let beat = min(max(10 / Double(steps.count + 1), 0.34), 0.85) * tempo
        // It begins at once with the first, as it was made.
        go(to: steps[0])
        player = Task { [weak self] in
            for id in steps.dropFirst() {
                try? await Task.sleep(for: .seconds(beat))
                guard let self, !Task.isCancelled else { return }
                self.go(to: id)
            }
            try? await Task.sleep(for: .seconds(beat))
            guard let self, !Task.isCancelled else { return }
            self.comeBack()
            self.playing = false
            self.player = nil
        }
    }

    /// Stops playing the story, where it is.
    func stop() {
        player?.cancel()
        player = nil
        if playing { playing = false }
    }

    /// The versions a story is told by: all of them while they are few, else the named ones and
    /// enough of the others, evenly spread, to tell it in some thirty steps.
    static func story(of list: [DesignVersion]) -> [UUID] {
        let most = 30
        guard list.count > most else { return list.map(\.id) }
        let named = list.indices.filter { list[$0].isNamed }
        let room = max(most - named.count, 2)
        let spread = (0..<room).map { Int((Double($0) / Double(room - 1) * Double(list.count - 1)).rounded()) }
        return Set(named + spread).sorted().map { list[$0].id }
    }

    // MARK: Going back

    /// A click on the canvas while looking back picks a layer that differs, to bring back alone.
    func pick(at p: CGPoint) {
        guard var t = travel else { return }
        guard let hit = layer(at: p) else { return }
        if t.picked.contains(hit) { t.picked.remove(hit) } else { t.picked.insert(hit) }
        travel = t
    }

    /// The layer that differs from now under a canvas point, as the design was then: the
    /// smallest, as it is the one most likely meant.
    func layer(at p: CGPoint) -> UUID? {
        guard let t = travel else { return nil }
        return t.changed.union(t.gone).compactMap { id -> (UUID, CGFloat)? in
            guard let f = t.doc.absoluteFrame(of: id), f.contains(p) else { return nil }
            return (id, f.width * f.height)
        }.min { $0.1 < $1.1 }?.0
    }

    /// Goes back to the version shown: the design becomes what it was then, its notes staying as
    /// they are now. What it is now is kept as a named version first.
    func restore() {
        guard let t = travel else { return }
        restore(t.at)
    }

    func restore(_ id: UUID) {
        guard let store, !store.isReadOnly, let version = list.first(where: { $0.id == id }), let past = document(id) else { return }
        showNow()
        // Already as it was then: nothing to go back to, and nothing to keep.
        var then = past, now = store.sharedDoc
        then.viewport = nil
        now.viewport = nil
        then.notes = nil
        now.notes = nil
        guard then != now else { return }
        let when = version.name ?? version.date.formatted(date: .abbreviated, time: .shortened)
        take(store.sharedDoc, name: String(localized: "Before going back to \(when)"))
        store.edit("Go Back to Version") { doc in
            let viewport = doc.viewport, notes = doc.notes
            doc = past
            doc.viewport = viewport
            doc.notes = notes
        }
    }

    /// Brings the picked layers back as they were, into the design as it is now: each where it
    /// is now, or, if it has gone since, where it was.
    func bringBack() {
        guard let store, !store.isReadOnly, let t = travel, !t.picked.isEmpty else { return }
        let past = t.doc
        let ids = t.picked
        showNow()
        store.edit(ids.count == 1 ? "Bring Back Layer" : "Bring Back Layers") { doc in
            // Those inside something else brought back come with it; the outer ones first, so
            // what they go into is there before them.
            let outer = ids.filter { id in !past.ancestors(of: id).contains { ids.contains($0.id) } }
                .sorted { (past.path(of: $0)?.indices ?? []).lexicographicallyPrecedes(past.path(of: $1)?.indices ?? []) }
            for id in outer {
                guard let old = past.node(id) else { continue }
                if doc.node(id) != nil {
                    doc.update(id) { $0 = old }
                } else if let parent = past.parent(of: id), let there = doc.path(of: parent.id) {
                    let index = past.path(of: id)?.indices.last ?? 0
                    let count = doc.node(parent.id)?.children.count ?? 0
                    doc.insert(old, at: NodePath(indices: there.indices + [min(index, count)]))
                } else {
                    var loose = old
                    if let frame = past.absoluteFrame(of: id) { loose.frame = frame }
                    doc.nodes.append(loose)
                }
            }
        }
        store.selection = ids.filter { store.doc.node($0) != nil }.sorted { $0.uuidString < $1.uuidString }
        broughtBack = (store.selection, Date())
    }

    func dropPicked() {
        travel?.picked = []
    }
}

extension VersionFiles {
    /// The versions this Mac sees of a design.
    @MainActor static func index(of design: URL) -> [DesignVersion] { index(of: design, replica: Sharing.replica) }

    @MainActor static func writeIndex(_ list: [DesignVersion], to design: URL) throws {
        try writeIndex(list, to: design, replica: Sharing.replica)
    }
}
