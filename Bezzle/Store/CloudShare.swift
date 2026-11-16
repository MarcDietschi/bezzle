import Foundation
import Observation

/// An open design's room on the relay, while it is shared by link. It sends this Mac's changes
/// there as records of its own, sealed with the link's key, and takes in everyone else's, merged
/// as all changes are (see `SharedDesign`): a record is written once and never over, so nothing
/// anyone does is lost. Pictures and named versions go and come the same way. The room says when
/// there is something new through the live socket; it is looked at every so often all the same.
///
/// What this Mac has done with the room is kept in its own folder in the design, `cloud.json`,
/// after the changes it took in are in the design's parts, so that nothing is ever taken for read
/// that is not kept.
@Observable
final class CloudShare {
    let keys: ShareKeys
    let replica: String
    /// Who works on the design, as their records say.
    private(set) var people: [String: FolderShare.Person] = [:]
    /// Why the relay could not be reached, until it can.
    private(set) var problem: String?

    @ObservationIgnored private weak var collaboration: Collaboration?
    @ObservationIgnored private var progress = Progress()
    @ObservationIgnored private var listedFully = false
    @ObservationIgnored private var syncing = false
    @ObservationIgnored private var again = false
    @ObservationIgnored private var stopped = false
    @ObservationIgnored private var waiting: Task<Void, Never>?
    @ObservationIgnored private var timer: Timer?
    /// Changes the live room brought, which their makers send too; sent from here as well, should
    /// they not come to.
    @ObservationIgnored private var relayedChanges: [SharedDesign] = []
    /// The pictures the design shows.
    @ObservationIgnored private var shown: Set<String> = []
    /// Pictures asked the room for and not there yet, with when.
    @ObservationIgnored private var asked: [String: Date] = [:]

    /// What this Mac has done with the room so far.
    typealias Progress = CloudRoom.Progress

    init(keys: ShareKeys, replica: String) {
        self.keys = keys
        self.replica = replica
    }

    var sentUpTo: Int64 { progress.sentUpTo }

    // MARK: Opening and closing

    func start(for collaboration: Collaboration) {
        self.collaboration = collaboration
        stopped = false
        progress = Self.progress(of: collaboration.url, replica: replica) ?? Progress()
        let timer = Timer(timeInterval: 30, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.syncSoon() } }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        syncSoon()
    }

    func stop() {
        stopped = true
        timer?.invalidate()
        timer = nil
        waiting?.cancel()
        waiting = nil
    }

    // MARK: What happens to the design

    /// Something was changed here: it goes a moment from now, with whatever follows it.
    func changed() { syncSoon(after: 1.5) }

    func relayed(_ changes: [SharedDesign]) { relayedChanges += changes.filter { !$0.isEmpty } }

    /// The design shows these pictures now: any not in the room go there.
    func offer(_ pictures: Set<String>) {
        guard pictures != shown else { return }
        shown = pictures
        if !pictures.subtracting(progress.pictures).isEmpty { syncSoon(after: 1.5) }
    }

    /// The room said it has records up to `upTo`.
    func recordsChanged(upTo: UInt64) {
        if Int64(clamping: upTo) > progress.seq { syncSoon() }
    }

    /// The owner stopped sharing the design.
    func gone() {
        guard !stopped else { return }
        stop()
        Sharing.log.notice("Room \(self.keys.room.prefix(8), privacy: .public) is no longer shared")
        collaboration?.unshared(own: Sharing.shared.owns(keys.room))
    }

    /// Looks at the room a moment from now, sending what is new here first.
    func syncSoon(after delay: Double = 0) {
        guard !stopped else { return }
        if syncing {
            again = true
            return
        }
        waiting?.cancel()
        waiting = Task { [weak self] in
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            guard !Task.isCancelled else { return }
            await self?.sync()
        }
    }

    #if DEBUG
    /// Sends and receives now, for tests, once whatever is going on is done.
    func syncForTesting() async {
        while syncing { try? await Task.sleep(for: .milliseconds(5)) }
        waiting?.cancel()
        await sync()
    }
    #endif

    private func sync() async {
        guard !syncing else {
            again = true
            return
        }
        syncing = true
        repeat {
            again = false
            await syncOnce()
        } while again && !stopped
        syncing = false
    }

    private func syncOnce() async {
        guard let collaboration, let server = Sharing.shared.server, !stopped else { return }
        do {
            try await send(collaboration, server)
            try await receive(collaboration, server)
            if problem != nil { problem = nil }
        } catch ShareError.gone {
            gone()
        } catch {
            Sharing.log.error("Room \(self.keys.room.prefix(8), privacy: .public): \(String(describing: error), privacy: .public)")
            let now = String(localized: "Bezzle cannot connect right now. Your changes are kept and go out once it can.")
            if problem != now { problem = now }
        }
    }

    // MARK: Sending

    /// Sends everything there is to send, pictures counted as they go: before a link is handed out.
    func sendEverything(progress report: @escaping (Int, Int) -> Void) async throws {
        guard let collaboration, let server = Sharing.shared.server else { throw ShareError.unreachable }
        if let store = collaboration.store { shown.formUnion(Collaboration.pictures(in: store.sharedDoc)) }
        try await send(collaboration, server, report: report)
        if let store = collaboration.store {
            for version in store.versions.list where version.isNamed && version.shared == true {
                if let data = try? Data(contentsOf: VersionFiles.file(version.id, of: collaboration.url)) {
                    try await sendVersion(version, data: data, to: server)
                }
            }
        }
    }

    func sendMeta(_ meta: ShareMeta) async throws {
        guard let server = Sharing.shared.server, let owner = Sharing.shared.ownerToken(for: keys.room),
              let data = FolderShare.encode(meta), let sealed = keys.seal(data, about: ShareRecord.meta.key) else { throw ShareError.unreachable }
        try await server.put(keys.room, ShareRecord.meta.key, sealed, write: keys.writeToken, writer: nil, owner: owner)
    }

    /// A version named here, for everyone.
    func sendVersion(_ version: DesignVersion, data: Data) {
        guard let server = Sharing.shared.server else { return }
        Task {
            do { try await sendVersion(version, data: data, to: server) } catch {
                Sharing.log.error("Could not send a version: \(String(describing: error), privacy: .public)")
            }
        }
    }

    private func sendVersion(_ version: DesignVersion, data: Data, to server: ShareServer) async throws {
        let designKey = ShareRecord.versionDesign(version.id).key, key = ShareRecord.version(version.id).key
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        guard let sealedDesign = keys.seal(data, about: designKey), let about = try? encoder.encode(version),
              let sealed = keys.seal(about, about: key) else { return }
        if progress.known[designKey] == nil {
            try await server.put(keys.room, designKey, sealedDesign, write: keys.writeToken, writer: nil, owner: nil)
        }
        try await server.put(keys.room, key, sealed, write: keys.writeToken, writer: nil, owner: nil)
    }

    /// Sends what was changed here since this Mac's last record, with what the live room brought,
    /// and now and then the whole design; then pictures not there yet, and who this Mac is.
    private func send(_ collaboration: Collaboration, _ server: ShareServer, report: ((Int, Int) -> Void)? = nil) async throws {
        // What goes is kept here first.
        collaboration.persist()
        await Self.saved()
        let state = collaboration.state
        var changes = state.changes(by: replica, after: progress.sentUpTo)
        let relayed = relayedChanges
        for design in relayed { changes.merge(design) }
        var own = progress.parts.compactMap { FolderShare.Part.record($0)?.part }
        let writer = Sharing.shared.writer(for: keys.room)
        // The owner's first: the whole design, for everyone who comes to start from.
        let first = own.isEmpty && Sharing.shared.owns(keys.room)
        if !changes.isEmpty || first {
            let upTo = FolderShare.nextUpTo(state.clock.time, after: own)
            let part = FolderShare.Part(first ? .whole : .changes, upTo: upTo)
            try await put(part, first ? state : changes, server, writer)
            own.append(part)
            progress.sentUpTo = max(progress.sentUpTo, state.clock.time)
            relayedChanges.removeFirst(min(relayed.count, relayedChanges.count))
            if !first, FolderShare.shouldFold(own) {
                let whole = FolderShare.Part(.whole, upTo: upTo)
                try await put(whole, state, server, writer)
                own.append(whole)
                for old in FolderShare.folded(own, into: upTo) {
                    let key = old.record(of: replica)
                    try await server.delete(keys.room, key, write: keys.writeToken, writer: writer)
                    progress.parts.removeAll { $0 == key }
                    progress.known[key] = nil
                    progress.read.remove(key)
                }
            }
            keepProgress()
        }
        try await sendPictures(collaboration, server, report: report)
        let me = FolderSync.me(replica: replica, since: progress.introduced?.since ?? Collaboration.now)
        if progress.introduced != me, let data = FolderShare.encode(me), let sealed = keys.seal(data, about: ShareRecord.person(replica).key) {
            try await server.put(keys.room, ShareRecord.person(replica).key, sealed, write: keys.writeToken, writer: writer, owner: nil)
            progress.introduced = me
            keepProgress()
        }
    }

    private func put(_ part: FolderShare.Part, _ design: SharedDesign, _ server: ShareServer, _ writer: String) async throws {
        let key = part.record(of: replica)
        guard let sealed = await Self.seal(design, keys, about: key) else { throw ShareError.refused(0) }
        try await server.put(keys.room, key, sealed, write: keys.writeToken, writer: writer, owner: nil)
        progress.parts.append(key)
        progress.read.insert(key)
        progress.known[key] = progress.known[key] ?? 0
    }

    private func sendPictures(_ collaboration: Collaboration, _ server: ShareServer, report: ((Int, Int) -> Void)?) async throws {
        let images = collaboration.url.appendingPathComponent(DesignFile.imagesFolder, isDirectory: true)
        let names = shown.subtracting(progress.pictures).filter { FileManager.default.fileExists(atPath: images.appendingPathComponent($0).path) }.sorted()
        report?(0, names.count)
        for (i, name) in names.enumerated() {
            let key = ShareRecord.picture(keys.pictureName(name)).key
            if progress.known[key] == nil {
                guard let sealed = await Self.seal(file: images.appendingPathComponent(name), keys, about: key) else { continue }
                do {
                    try await server.put(keys.room, key, sealed, write: keys.writeToken, writer: nil, owner: nil)
                } catch ShareError.refused(413) {
                    Sharing.log.error("A picture is too large for the relay: \(name, privacy: .public)")
                }
            }
            progress.pictures.insert(name)
            report?(i + 1, names.count)
            if i % 8 == 7 { keepProgress() }
        }
        if !names.isEmpty { keepProgress() }
    }

    // MARK: Receiving

    private func receive(_ collaboration: Collaboration, _ server: ShareServer) async throws {
        let fetched = try await Self.fetch(keys, from: server, progress: progress, fully: !listedFully, replica: replica)
        listedFully = true
        progress = fetched.progress
        if fetched.again { again = true }
        for (who, person) in fetched.people where people[who] != person { people[who] = person }
        if let meta = fetched.meta, var link = collaboration.link, !link.ended,
           link.title != meta.title || link.ownerName != meta.owner {
            link.title = meta.title
            link.ownerName = meta.owner
            try? SharingFiles.write(link, to: collaboration.url)
            collaboration.retitled(link)
        }
        if !fetched.changes.isEmpty {
            collaboration.receive(fetched.changes, from: .cloud)
            collaboration.persist()
            await Self.saved()
        }
        keepProgress()
        if let store = collaboration.store {
            for version in fetched.versions where !store.versions.list.contains(where: { $0.id == version.id && $0.name == version.name }) {
                var data = try? Data(contentsOf: VersionFiles.file(version.id, of: collaboration.url))
                if data == nil {
                    let key = ShareRecord.versionDesign(version.id).key
                    data = try await server.get(keys.room, key, read: keys.readToken).flatMap { keys.open($0, about: key) }
                }
                if let data { store.versions.arrived(version, data: data) }
            }
        }
        try await fetchPictures(collaboration, server)
    }

    /// Pictures the design shows that are not here yet, from the room.
    private func fetchPictures(_ collaboration: Collaboration, _ server: ShareServer) async throws {
        let design = collaboration.url
        let wanted = shown.isEmpty ? Collaboration.pictures(in: collaboration.state.flatDesign().document()) : shown
        for name in wanted.sorted() where !Arrivals.hasPicture(name, of: design) {
            guard !name.hasPrefix("."), (name as NSString).lastPathComponent == name else { continue }
            let key = ShareRecord.picture(keys.pictureName(name)).key
            if let last = asked[name], Date().timeIntervalSince(last) < 20 { continue }
            asked[name] = Date()
            guard progress.known[key] != nil, let sealed = try await server.get(keys.room, key, read: keys.readToken),
                  let data = await Self.open(file: sealed, keys, about: key) else { continue }
            do {
                try Self.keep(picture: data, named: name, in: design)
            } catch {
                Sharing.log.error("Could not keep a picture: \(error.localizedDescription, privacy: .public)")
                continue
            }
            asked[name] = nil
            progress.pictures.insert(name)
            collaboration.store?.pictureArrived(name)
            collaboration.live?.arrived(name)
        }
    }

    /// What a look at the room found.
    typealias Fetched = CloudRoom.Fetched
    /// A design that came from a link: everything in its room, as one design.
    typealias Arrived = CloudRoom.Arrived

    /// Reads what is new in the room since `progress` (see `CloudRoom.fetch`).
    @concurrent nonisolated static func fetch(_ keys: ShareKeys, from server: ShareServer, progress: Progress, fully: Bool,
                                              replica: String) async throws -> Fetched {
        try await CloudRoom.fetch(keys, from: server, progress: progress, fully: fully, replica: replica)
    }

    static func download(_ keys: ShareKeys, from server: ShareServer, meta: (ShareMeta) -> Void) async throws -> Arrived {
        let fetched = try await fetch(keys, from: server, progress: Progress(), fully: true, replica: Sharing.replica)
        if let found = fetched.meta { meta(found) }
        return try CloudRoom.arrived(fetched)
    }

    /// Keeps a picture that came from the room: in the design, or beside it while the design is in
    /// a folder a sync service keeps in step, where whoever placed it writes it (`Arrivals`).
    nonisolated static func keep(picture data: Data, named name: String, in design: URL) throws {
        if SyncedFolders.service(of: design) != nil {
            try Arrivals.keep(data, as: name, in: Arrivals.images(of: design))
            return
        }
        let images = design.appendingPathComponent(DesignFile.imagesFolder, isDirectory: true)
        try DesignFile.makeFolder(images, in: design)
        try data.write(to: images.appendingPathComponent(name), options: .atomic)
    }

    // MARK: Keeping what was done

    private static func progressFile(_ design: URL, _ replica: String) -> URL {
        FolderSync.folder(of: replica, in: design).appendingPathComponent("cloud.json")
    }

    static func progress(of design: URL, replica: String) -> Progress? {
        (try? Data(contentsOf: progressFile(design, replica))).flatMap { FolderShare.decode(Progress.self, from: $0) }
    }

    /// Keeps what was done with the room, on the queue the design is saved on, after what was taken in.
    static func keep(_ progress: Progress, of design: URL, replica: String) {
        let file = progressFile(design, replica)
        guard let data = FolderShare.encode(progress) else { return }
        DocumentStore.saving.async {
            guard (try? DesignFile.makeFolder(file.deletingLastPathComponent(), in: design)) != nil else { return }
            try? data.write(to: file, options: .atomic)
        }
    }

    private func keepProgress() {
        guard let url = collaboration?.url else { return }
        Self.keep(progress, of: url, replica: replica)
    }

    /// Once every save asked for so far is on disk, without holding the main thread.
    private static func saved() async {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in DocumentStore.saving.async { done.resume() } }
    }

    // MARK: Sealing, away from the main thread

    @concurrent nonisolated static func seal(_ design: SharedDesign, _ keys: ShareKeys, about key: String) async -> Data? {
        FolderShare.pack(design).flatMap { keys.seal($0, about: key) }
    }

    @concurrent nonisolated static func seal(file: URL, _ keys: ShareKeys, about key: String) async -> Data? {
        (try? Data(contentsOf: file)).flatMap { keys.seal($0, about: key) }
    }

    @concurrent nonisolated static func open(file sealed: Data, _ keys: ShareKeys, about key: String) async -> Data? {
        keys.open(sealed, about: key)
    }
}
