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
        sentUpTo = try c.decodeIfPresent(Int64.self, forKey: .sentUpTo) ?? 0
        changedUpTo = try c.decodeIfPresent(Int64.self, forKey: .changedUpTo) ?? 0
        sentPictures = try c.decodeIfPresent(Set<String>.self, forKey: .sentPictures) ?? []
        changeRecords = try c.decodeIfPresent(Set<String>.self, forKey: .changeRecords) ?? []
        folding = try c.decodeIfPresent([String].self, forKey: .folding) ?? []
        snapshotFields = try c.decodeIfPresent(Data.self, forKey: .snapshotFields)
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
        didSet { if link != oldValue { linkChanged = true } }
    }
    @ObservationIgnored private(set) var state: SharedDesign
    @ObservationIgnored private(set) weak var store: DocumentStore?
    /// The layers as this Mac last showed them, to tell what was changed here since.
    @ObservationIgnored private var base = FlatDesign()
    @ObservationIgnored private var decoded: [UUID: (layer: SharedLayer, node: Node)] = [:]
    /// Others' changes taken in but not shown yet, while a drag or a scrub is going on.
    @ObservationIgnored private var unshown = false
    @ObservationIgnored private var stateChanged = false
    @ObservationIgnored private var linkChanged = false

    var zone: String { link.zone }
    var isOwner: Bool { link.isOwner }

    init(url: URL, link: SharingLink, state: SharedDesign) {
        self.url = url
        self.link = link
        self.state = state
    }

    /// The shared design at `url`, if it is one. A copy of a shared design, as the Finder makes,
    /// is not shared: it becomes a design of its own. One shared from a build for the other iCloud
    /// environment still keeps what is done to it here, to send when that build opens it.
    static func open(_ url: URL) -> Collaboration? {
        guard let link = SharingFiles.link(of: url), let state = SharingFiles.state(of: url) else { return nil }
        guard link.environment != CloudSync.environment || CloudSync.shared.claim(link.zone, at: url) else {
            SharingFiles.unlink(url)
            return nil
        }
        return Collaboration(url: url, link: link, state: state)
    }

    /// The design as it is shared, which is what this Mac shows.
    func document() -> BezzleDocument {
        base = state.flatDesign(reusing: &decoded)
        return base.document()
    }

    func attach(to store: DocumentStore) {
        self.store = store
        CloudSync.shared.opened(self)
        takeIn(store.sharedDoc)
    }

    func close() {
        CloudSync.shared.closed(self)
    }

    func moved(to url: URL) {
        self.url = url
        _ = CloudSync.shared.claim(zone, at: url)
    }

    // MARK: Both ways

    /// Takes in what was changed here since last time, to be sent to the others.
    func takeIn(_ doc: BezzleDocument) {
        let now = FlatDesign(doc)
        if state.absorb(now, since: base, by: CloudSync.replica, at: Self.now) {
            link.changedUpTo = state.clock.time
            stateChanged = true
            CloudSync.shared.haveChanges(in: self)
        }
        base = now
        CloudSync.shared.sendPictures(Self.pictures(in: doc), of: self)
    }

    /// Takes in changes from the others, and shows them unless a drag is going on. What was done
    /// here is taken in first, so it is kept as it is.
    func receive(_ changes: [SharedDesign]) {
        if let store { takeIn(store.sharedDoc) }
        var changed = false
        for c in changes where !c.isEmpty {
            if !state.merge(c).isEmpty { changed = true }
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
        store.showChangesFromOthers(map.document())
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
    static func pictures(in doc: BezzleDocument) -> Set<String> {
        var names = Set<String>()
        func visit(_ n: Node) {
            if let asset = n.fill.image?.asset { names.insert(asset) }
            n.children.forEach(visit)
            n.mask?.forEach(visit)
        }
        doc.nodes.forEach(visit)
        return names
    }
}
