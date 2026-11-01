import Foundation
import Observation

/// What ties a design on this Mac to the copy everyone shares in iCloud. It is kept in the
/// design's package, beside the shared design itself.
nonisolated struct SharingLink: Codable, Equatable, Sendable {
    /// The design's record zone in iCloud.
    var zone: String
    /// Whose iCloud the zone is in: nil for this Mac's own account, else the owner's record name.
    var owner: String?
    /// Which of the container's environments the zone is in (see `CloudSync.environment`).
    var environment: String
    /// The owner's name, as their invitation gave it, for a design someone else shared.
    var ownerName: String?
    /// Whether there is a share of it that others can join: for the owner's own design, which
    /// stays in their iCloud when they stop sharing it.
    var shared = false
    /// Someone else's design this Mac has no part in any more, as they stopped sharing it or
    /// took this Mac's account off it. It is kept as it last was, to look at, and to save a copy of.
    var ended = false
    /// The latest of this Mac's own changes the others have been sent.
    var sentUpTo: Int64 = 0
    /// The latest change made here, so what is still to be sent is known without reading the design.
    var changedUpTo: Int64 = 0
    /// Pictures already in iCloud, sent from here or fetched.
    var sentPictures: Set<String> = []
    /// The change records in the zone, for the owner to fold into one now and then.
    var changeRecords: Set<String> = []
    /// Those being folded into the snapshot on its way, to delete once it is there.
    var folding: [String] = []
    /// The snapshot record's system fields, so a new snapshot is saved over it.
    var snapshotFields: Data?

    init(zone: String, owner: String?, environment: String = "Development") {
        self.zone = zone
        self.owner = owner
        self.environment = environment
    }

    var isOwner: Bool { owner == nil }
    var hasUnsent: Bool { changedUpTo > sentUpTo }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        zone = try c.decode(String.self, forKey: .zone)
        owner = try c.decodeIfPresent(String.self, forKey: .owner)
        environment = try c.decodeIfPresent(String.self, forKey: .environment) ?? "Development"
        ownerName = try c.decodeIfPresent(String.self, forKey: .ownerName)
        shared = try c.decodeIfPresent(Bool.self, forKey: .shared) ?? false
        ended = try c.decodeIfPresent(Bool.self, forKey: .ended) ?? false
        sentUpTo = try c.decodeIfPresent(Int64.self, forKey: .sentUpTo) ?? 0
        changedUpTo = try c.decodeIfPresent(Int64.self, forKey: .changedUpTo) ?? 0
        sentPictures = try c.decodeIfPresent(Set<String>.self, forKey: .sentPictures) ?? []
        changeRecords = try c.decodeIfPresent(Set<String>.self, forKey: .changeRecords) ?? []
        folding = try c.decodeIfPresent([String].self, forKey: .folding) ?? []
        snapshotFields = try c.decodeIfPresent(Data.self, forKey: .snapshotFields)
    }
}

/// How a design is shared, as the home screen and its window show it.
enum SharingMark: Equatable {
    /// One of this Mac's own, shared with others.
    case shared
    /// Someone else's, shared with this Mac.
    case sharedBy(String?)
    /// Someone else's, no longer shared with this Mac.
    case ended

    var title: LocalizedStringResource {
        switch self {
        case .shared: "Shared"
        case .sharedBy(let owner?): "Shared by \(owner)"
        case .sharedBy(nil): "Shared with you"
        case .ended: "No longer shared"
        }
    }
}

extension SharingLink {
    /// Nil for one of this Mac's own designs not shared with anyone just now.
    var mark: SharingMark? {
        if ended { return .ended }
        if !isOwner { return .sharedBy(ownerName) }
        return shared ? .shared : nil
    }
}

/// Where a shared design keeps what ties it to iCloud: a folder in its package.
nonisolated enum SharingFiles {
    static let folderName = "sharing"

    static func folder(of design: URL) -> URL { design.appendingPathComponent(folderName, isDirectory: true) }
    private static func linkFile(_ design: URL) -> URL { folder(of: design).appendingPathComponent("link.json") }
    private static func stateFile(_ design: URL) -> URL { folder(of: design).appendingPathComponent("design.json") }

    static func link(of design: URL) -> SharingLink? {
        (try? Data(contentsOf: linkFile(design))).flatMap { try? JSONDecoder().decode(SharingLink.self, from: $0) }
    }

    static func state(of design: URL) -> SharedDesign? {
        (try? Data(contentsOf: stateFile(design))).flatMap { try? JSONDecoder().decode(SharedDesign.self, from: $0) }
    }

    static func write(_ link: SharingLink, to design: URL) throws {
        try FileManager.default.createDirectory(at: folder(of: design), withIntermediateDirectories: true)
        try JSONEncoder().encode(link).write(to: linkFile(design), options: .atomic)
    }

    static func write(_ state: SharedDesign, to design: URL) throws {
        try FileManager.default.createDirectory(at: folder(of: design), withIntermediateDirectories: true)
        try JSONEncoder().encode(state).write(to: stateFile(design), options: .atomic)
    }

    /// Makes it a design of this Mac's own again, as it now is.
    static func unlink(_ design: URL) {
        try? FileManager.default.removeItem(at: folder(of: design))
    }
}

/// An open design that is shared. It takes in what is done here, to be sent, and shows what the
/// others did, keeping everything done here: what the others changed is merged in property by
/// property (see `SharedDesign`), never put over the design whole.
///
/// The shared design in the package is what counts; the design's own file is written after it,
/// and if Bezzle stops in between, the design opens from the shared one.
@Observable
final class Collaboration {
    @ObservationIgnored private(set) var url: URL
    @ObservationIgnored var link: SharingLink {
        didSet {
            guard link != oldValue else { return }
            linkChanged = true
            if mark != link.mark { mark = link.mark }
        }
    }
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
    @ObservationIgnored private var stateChanged = false
    @ObservationIgnored private var linkChanged = false
    /// Who made what others changed, by layer, until it is shown.
    @ObservationIgnored private var unshownAuthors: [UUID: String] = [:]
    /// The design's live room, while others have it open too and there is a relay to meet on.
    private(set) var live: LiveRoom?
    /// This Mac's name among those sharing the design, which its changes carry. Tests give each
    /// Mac they stand for a name of its own.
    @ObservationIgnored var replica = CloudSync.replica

    var zone: String { link.zone }
    var isOwner: Bool { link.isOwner }

    init(url: URL, link: SharingLink, state: SharedDesign) {
        self.url = url
        self.link = link
        self.state = state
        mark = link.mark
    }

    /// Whether it can only be looked at: someone else's design this Mac no longer shares.
    var isReadOnly: Bool { link.ended }

    /// The shared design at `url`, if it is one. A copy of a shared design, as the Finder makes,
    /// is not shared: it becomes a design of its own. One shared from a build for the other iCloud
    /// environment still keeps what is done to it here, to send when that build opens it.
    static func open(_ url: URL) -> Collaboration? {
        guard let link = SharingFiles.link(of: url), let state = SharingFiles.state(of: url) else { return nil }
        guard link.ended || link.environment != CloudSync.environment || CloudSync.shared.claim(link.zone, at: url) else {
            SharingFiles.unlink(url)
            return nil
        }
        return Collaboration(url: url, link: link, state: state)
    }

    /// The design as it is shared, which is what this Mac shows.
    func document() -> BezzleDocument {
        base = state.flatDesign(reusing: &decoded)
        baseDoc = nil
        return base.document()
    }

    func attach(to store: DocumentStore) {
        self.store = store
        CloudSync.shared.opened(self)
        takeIn(store.sharedDoc)
        live = LiveRoom.open(for: self, store: store)
    }

    func close() {
        live?.leave()
        live = nil
        CloudSync.shared.closed(self)
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
        _ = CloudSync.shared.claim(zone, at: url)
    }

    // MARK: Both ways

    /// Takes in what was changed here since last time, to be sent to the others: only the
    /// artboards and loose layers that changed, when the layers as this Mac last showed them are
    /// known to be those of the design taken in last; otherwise the whole design.
    func takeIn(_ doc: BezzleDocument) {
        guard !link.ended else { return }
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
        CloudSync.shared.sendPictures(pictures, of: self)
        live?.offer(pictures)
    }

    private func absorb(_ now: FlatDesign, since was: FlatDesign) {
        if state.absorb(now, since: was, by: replica, at: Self.now) {
            link.changedUpTo = state.clock.time
            stateChanged = true
            CloudSync.shared.haveChanges(in: self)
            live?.relay()
        }
    }

    /// Takes in changes from the others, and shows them unless a drag is going on. What was done
    /// here is taken in first, so it is kept as it is.
    func receive(_ changes: [SharedDesign]) {
        if let store { takeIn(store.sharedDoc) }
        var changed = false
        for c in changes where !c.isEmpty {
            let layers = state.merge(c)
            guard !layers.isEmpty else { continue }
            changed = true
            let authors = c.authors
            for id in layers { if let by = authors[id] { unshownAuthors[id] = by } }
        }
        guard changed else { return }
        stateChanged = true
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

    /// Writes what changed to the package, on the queue the design itself is saved on and ahead
    /// of it.
    func persist() {
        guard stateChanged || linkChanged else { return }
        let url = url, link = link, state: SharedDesign? = stateChanged ? state : nil
        stateChanged = false
        linkChanged = false
        DocumentStore.saving.async {
            do {
                if let state { try SharingFiles.write(state, to: url) }
                try SharingFiles.write(link, to: url)
            } catch {
                NSLog("Bezzle could not save what ties %@ to iCloud: %@", url.path, error.localizedDescription)
            }
        }
    }

    // MARK: Designs not open

    /// Takes changes from the others into a shared design that is not open: the shared design
    /// first, then the design's own file from it.
    static func merge(_ changes: [SharedDesign], intoDesignAt url: URL) {
        DocumentStore.finishSaving()
        guard var state = SharingFiles.state(of: url) else { return }
        var changed = false
        for c in changes where !c.isEmpty {
            if !state.merge(c).isEmpty { changed = true }
        }
        guard changed else { return }
        var doc = state.flatDesign().document()
        doc.viewport = (try? DesignFile.read(url))?.viewport
        let merged = state
        DocumentStore.saving.sync {
            do {
                try SharingFiles.write(merged, to: url)
                try DesignFile.write(doc, to: url)
            } catch {
                NSLog("Bezzle could not save changes from others to %@: %@", url.path, error.localizedDescription)
            }
        }
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
