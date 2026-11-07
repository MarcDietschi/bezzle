import Foundation
import Observation

/// What ties a design to its room on the relay, the same for everyone who has it, kept in its
/// package as `sharing/share.json`. Its secret is the design's link: whoever has the package
/// has the link too, as they have the design.
nonisolated struct ShareLink: Codable, Equatable, Sendable {
    /// The link's secret, as base64url. Empty in a design someone shared through iCloud, which
    /// is no longer shared now that Bezzle shares through its relay.
    var secret: String
    /// The design's name as its owner gave it.
    var title: String?
    /// The name of whoever shared it, as they gave it.
    var ownerName: String?
    /// Its owner stopped sharing it, so it is kept as it last was, to look at and to save a copy of.
    var ended = false

    init(secret: String, title: String? = nil, ownerName: String? = nil, ended: Bool = false) {
        self.secret = secret
        self.title = title
        self.ownerName = ownerName
        self.ended = ended
    }

    /// The room's keys, while it is shared.
    var keys: ShareKeys? { ended ? nil : ShareKeys(link: secret) }

    /// The page on Bezzle's website that hands the link to Bezzle, in any browser.
    var page: URL? {
        guard keys != nil else { return nil }
        return URL(string: "https://bezzle.ch/open.html#2.\(secret)")
    }
}

/// How a design is shared, as the home screen and its window show it.
enum SharingMark: Equatable {
    /// Shared from this Mac, by link.
    case shared
    /// Someone else's, shared with this Mac by link.
    case sharedBy(String?)
    /// Someone else's, no longer shared.
    case ended
    /// Kept in a folder that Google Drive or the like keeps in step, where others work on it too.
    case inFolder(String)

    /// Whether the design may be given a new name here. Someone else's keeps the name it was
    /// shared under.
    var renamable: Bool {
        switch self {
        case .sharedBy, .ended: false
        case .shared, .inFolder: true
        }
    }

    var title: LocalizedStringResource {
        switch self {
        case .shared: "Shared"
        case .sharedBy(let owner?): "Shared by \(owner)"
        case .sharedBy(nil): "Shared with you"
        case .ended: "No longer shared"
        case .inFolder(let service): "Shared in \(service)"
        }
    }

    /// What it means, for help tags.
    var help: LocalizedStringResource {
        switch self {
        case .ended: "Read only: this design is no longer shared with you. Save a copy to keep working on it."
        case .inFolder(let service): "Shared through \(service): everyone’s changes come in as they are made"
        default: "Shared by link: everyone’s changes come in as they are made"
        }
    }
}

/// Where a design keeps what ties it to its share: a folder in its package, holding the link and
/// the parts everyone's changes are kept in (see `FolderShare`).
nonisolated enum SharingFiles {
    static let folderName = FolderShare.sharingFolder

    static func folder(of design: URL) -> URL { design.appendingPathComponent(folderName, isDirectory: true) }
    private static func linkFile(_ design: URL) -> URL { folder(of: design).appendingPathComponent("share.json") }

    static func link(of design: URL) -> ShareLink? {
        (try? Data(contentsOf: linkFile(design))).flatMap { FolderShare.decode(ShareLink.self, from: $0) }
    }

    static func write(_ link: ShareLink, to design: URL) throws {
        try DesignFile.makeFolder(folder(of: design), in: design)
        guard let data = FolderShare.encode(link) else { throw CocoaError(.fileWriteUnknown) }
        try data.write(to: linkFile(design), options: .atomic)
    }

    /// Makes it a design of its own again: no longer tied to a share. Its parts stay, should it be
    /// kept in a synced folder.
    static func unlink(_ design: URL) {
        try? FileManager.default.removeItem(at: linkFile(design))
    }

    /// Takes away everything of sharing, as from a copy that starts afresh.
    static func forget(_ design: URL) {
        try? FileManager.default.removeItem(at: folder(of: design))
    }

    // MARK: Once shared through iCloud

    private struct ICloudLink: Decodable {
        var owner: String?
        var ownerName: String?
    }

    /// A design shared through iCloud, which Bezzle no longer does: kept as it was last shared. One
    /// of this Mac's own is a design of its own again; someone else's is no longer shared, to look
    /// at and to save a copy of.
    static func leaveICloud(_ design: URL) {
        let old = folder(of: design).appendingPathComponent("link.json")
        guard let data = try? Data(contentsOf: old), let link = try? JSONDecoder().decode(ICloudLink.self, from: data) else { return }
        let stateFile = folder(of: design).appendingPathComponent("design.json")
        if let data = try? Data(contentsOf: stateFile), let state = try? JSONDecoder().decode(SharedDesign.self, from: data), !state.isEmpty {
            var doc = state.flatDesign().document()
            doc.viewport = (try? DesignFile.read(design))?.viewport
            try? DesignFile.write(doc, to: design)
        }
        if link.owner != nil {
            try? write(ShareLink(secret: "", ownerName: link.ownerName, ended: true), to: design)
        }
        try? FileManager.default.removeItem(at: old)
        try? FileManager.default.removeItem(at: stateFile)
    }
}

/// An open design that is shared: by link, through its room on the relay; through the synced
/// folder it is kept in; or both. It takes in what is done here, to be sent, and shows what the
/// others did, keeping everything done here: what the others changed is merged in property by
/// property (see `SharedDesign`), never put over the design whole.
///
/// Its parts in the package (see `FolderSync`) are what counts; the design's own file is written
/// after them, and if Bezzle stops in between, the design opens from its parts.
@Observable
final class Collaboration {
    /// Where the changes taken in came from.
    enum Source {
        /// The synced folder, which keeps them in their own files already.
        case folder
        /// The room's records on the relay.
        case cloud
        /// Someone in the live room, a moment after they made them.
        case relay
    }

    @ObservationIgnored private(set) var url: URL
    /// The design's share, while it has one or had one.
    @ObservationIgnored private(set) var link: ShareLink?
    /// How it is shared, for the window to show.
    private(set) var mark: SharingMark?
    @ObservationIgnored private(set) var state: SharedDesign
    @ObservationIgnored private(set) weak var store: DocumentStore?
    /// The layers as this Mac last showed them, to tell what was changed here since.
    @ObservationIgnored private var base = FlatDesign()
    /// The design `base` was made from, while it is: then only what changed in the next design
    /// taken in is gone through (see `FlatDesign.changes`). None when `base` comes from the shared
    /// design itself, as it does once others' changes are shown, and the next is gone through whole.
    @ObservationIgnored private var baseDoc: BezzleDocument?
    /// The pictures each artboard and loose layer of `baseDoc` shows.
    @ObservationIgnored private var basePictures: [UUID: Set<String>] = [:]
    @ObservationIgnored private var decoded: [UUID: (layer: SharedLayer, node: Node)] = [:]
    /// Others' changes taken in but not shown yet, while a drag or a scrub is going on.
    @ObservationIgnored private var unshown = false
    /// Who made what others changed, by layer, until it is shown.
    @ObservationIgnored private var unshownAuthors: [UUID: String] = [:]
    /// Others' changes from elsewhere than the folder, to keep with this Mac's parts.
    @ObservationIgnored private var toKeep: [SharedDesign] = []
    /// The latest change made here.
    @ObservationIgnored private(set) var changedUpTo: Int64 = 0
    /// Where the design keeps its parts; none only in tests that keep it in memory.
    @ObservationIgnored private(set) var folder: FolderSync?
    /// The design's room on the relay, while it is shared by link.
    private(set) var cloud: CloudShare?
    /// The design's live room, while there is a relay to meet on.
    private(set) var live: LiveRoom?
    /// This Mac's name among those sharing the design, which its changes carry. Tests give each
    /// Mac they stand for a name of its own.
    @ObservationIgnored var replica: String
    /// The live room's keys in tests that keep the design in memory.
    @ObservationIgnored private var keysInMemory: ShareKeys?

    init(url: URL, state: SharedDesign, folder: FolderSync?, link: ShareLink?, replica: String = Sharing.replica) {
        self.url = url
        self.state = state
        self.folder = folder
        self.link = link
        self.replica = replica
        changedUpTo = state.clock.time
        if let keys = link?.keys { cloud = CloudShare(keys: keys, replica: replica) }
        mark = Self.mark(link: link, folder: folder)
    }

    #if DEBUG
    /// A shared design kept in memory alone, for tests: its live room is `keys`'.
    convenience init(url: URL, state: SharedDesign = SharedDesign(), keys: ShareKeys) {
        self.init(url: url, state: state, folder: nil, link: nil)
        keysInMemory = keys
    }
    #endif

    /// Whether it can only be looked at: someone else's design this Mac no longer shares.
    var isReadOnly: Bool { link?.ended == true }

    /// The shared design at `url`, if it is one: shared by link, kept in a synced folder, or with
    /// parts from either. A copy of a design shared by link, as the Finder makes, is not shared: it
    /// becomes a design of its own.
    ///
    /// Tests standing for several Macs in one pass `claiming` false, as each would claim its own.
    static func open(_ url: URL, replica: String = Sharing.replica, claiming: Bool = true) -> Collaboration? {
        guard DesignFile.isPackage(url) else { return nil }
        SharingFiles.leaveICloud(url)
        var link = SharingFiles.link(of: url)
        if claiming, let keys = link?.keys, !Sharing.shared.claim(keys.room, at: url) {
            SharingFiles.unlink(url)
            link = nil
        }
        guard link != nil || FolderSync.applies(to: url), let opened = FolderSync.open(url, replica: replica) else { return nil }
        return Collaboration(url: url, state: opened.state, folder: opened.sync, link: link, replica: replica)
    }

    /// How it is shared now, for the window to show.
    func refreshMark() {
        let now = Self.mark(link: link, folder: folder)
        if mark != now { mark = now }
    }

    private static func mark(link: ShareLink?, folder: FolderSync?) -> SharingMark? {
        guard let link else { return folder?.mark }
        if link.ended { return .ended }
        guard let room = link.keys?.room else { return folder?.mark }
        return Sharing.shared.owns(room) ? .shared : .sharedBy(link.ownerName)
    }

    /// The keys the live room is found by and sealed with: the share's, or the synced folder's.
    var liveKeys: ShareKeys {
        if let cloud { return cloud.keys }
        if let folder { return folder.roomKeys }
        return keysInMemory ?? ShareKeys(secret: Data(repeating: 0, count: 32))!
    }

    /// The latest of this Mac's changes that everyone can have, from the room's records or the folder.
    var sentUpTo: Int64 { cloud?.sentUpTo ?? folder?.writtenUpTo ?? 0 }

    /// The design as it is shared, which is what this Mac shows.
    func document() -> BezzleDocument {
        base = state.flatDesign(reusing: &decoded)
        baseDoc = nil
        return base.document()
    }

    func attach(to store: DocumentStore) {
        self.store = store
        folder?.start(for: self)
        takeIn(store.sharedDoc)
        cloud?.start(for: self)
        live = LiveRoom.open(for: self, store: store)
    }

    func close() {
        live?.leave()
        live = nil
        cloud?.stop()
        folder?.stop()
    }

    /// The live room is another now: the design was shared, or no longer is, or its folder's
    /// room turned out to be a copy's.
    func roomChanged() {
        guard let store else { return }
        live?.leave()
        live = LiveRoom.open(for: self, store: store)
    }

    /// This Mac shared the design: its room on the relay is `link`'s.
    func shared(_ link: ShareLink) {
        self.link = link
        cloud?.stop()
        cloud = link.keys.map { CloudShare(keys: $0, replica: replica) }
        if store != nil { cloud?.start(for: self) }
        refreshMark()
        roomChanged()
    }

    /// Its owner gave the design another name, or theirs.
    func retitled(_ link: ShareLink) {
        self.link = link
        refreshMark()
    }

    /// The design is no longer shared by link. This Mac's own goes on as a design of its own;
    /// someone else's stays as it last was, read only.
    func unshared(own: Bool) {
        cloud?.stop()
        cloud = nil
        if own {
            link = nil
            SharingFiles.unlink(url)
        } else if var ended = link {
            ended.ended = true
            link = ended
            try? SharingFiles.write(ended, to: url)
        }
        refreshMark()
        roomChanged()
        Library.shared.refresh()
    }

    #if DEBUG
    /// Meets the others through `room` rather than the relay, for tests.
    func meet(in room: LiveRoom) {
        live?.leave()
        live = room
    }
    #endif

    func moved(to url: URL) {
        self.url = url
        if let room = cloud?.keys.room { _ = Sharing.shared.claim(room, at: url) }
        folder?.moved(to: url)
    }

    // MARK: Both ways

    /// Takes in what was changed here since last time, to be sent to the others: only the
    /// artboards and loose layers that changed, when the layers as this Mac last showed them are
    /// known to be those of the design taken in last; otherwise the whole design.
    func takeIn(_ doc: BezzleDocument) {
        guard !isReadOnly else { return }
        if let before = baseDoc {
            let (old, new) = FlatDesign.changes(from: before, to: doc)
            absorb(new, since: old)
            base.replace(old, with: new)
        } else {
            let now = FlatDesign(doc)
            absorb(now, since: base)
            base = now
        }
        var shown: [UUID: Set<String>] = [:]
        var was: [UUID: Node] = [:]
        for node in baseDoc?.nodes ?? [] { was[node.id] = node }
        for node in doc.nodes {
            if was[node.id] == node, let kept = basePictures[node.id] { shown[node.id] = kept } else { shown[node.id] = Self.pictures(in: [node]) }
        }
        baseDoc = doc
        basePictures = shown
        let pictures = shown.values.reduce(into: Set<String>()) { $0.formUnion($1) }
        cloud?.offer(pictures)
        live?.offer(pictures)
    }

    private func absorb(_ now: FlatDesign, since was: FlatDesign) {
        if state.absorb(now, since: was, by: replica, at: Self.now) {
            changedUpTo = state.clock.time
            cloud?.changed()
            live?.relay()
        }
    }

    /// Takes in changes from the others, and shows them unless a drag is going on. What was done
    /// here is taken in first, so it is kept as it is.
    func receive(_ changes: [SharedDesign], from source: Source) {
        if let store { takeIn(store.sharedDoc) }
        var changed = false
        for c in changes where !c.isEmpty {
            let layers = state.merge(c)
            if source != .folder { toKeep.append(c) }
            guard !layers.isEmpty else { continue }
            changed = true
            let authors = c.authors
            for id in layers { if let by = authors[id] { unshownAuthors[id] = by } }
        }
        if source == .relay { cloud?.relayed(changes) }
        guard changed else { return }
        unshown = true
        showIfIdle()
    }

    /// Shows what others changed, if that waited for a drag to end and it has.
    func showIfIdle() {
        guard unshown, let store, !store.inGesture || store.editingText != nil else { return }
        unshown = false
        takeIn(store.sharedDoc)
        let map = state.flatDesign(reusing: &decoded)
        base = map
        baseDoc = nil
        store.showChangesFromOthers(map.document())
        live?.glow(unshownAuthors)
        unshownAuthors = [:]
    }

    /// Writes what changed to the design's parts, on the queue the design itself is saved on and
    /// ahead of it.
    func persist() {
        folder?.persist(state, keeping: toKeep)
        toKeep = []
    }

    // MARK: Helpers

    static var now: Int64 { Int64(Date().timeIntervalSince1970 * 1000) }

    /// The pictures a design shows, in its layers and their masks.
    static func pictures(in doc: BezzleDocument) -> Set<String> { pictures(in: doc.nodes) }

    static func pictures(in nodes: [Node]) -> Set<String> {
        var names = Set<String>()
        func visit(_ n: Node) {
            for image in n.paintedPictures { names.formUnion(image.assets) }
            n.children.forEach(visit)
            n.mask?.forEach(visit)
        }
        nodes.forEach(visit)
        return names
    }
}
