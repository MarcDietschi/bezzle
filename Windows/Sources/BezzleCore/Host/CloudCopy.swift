import Foundation

// From Bezzle/Store/CloudShare.swift: an open design's room on the relay, while it is shared by
// link. It sends this computer's changes there as records of its own, sealed with the link's key
// (Live.swift's ShareKeys, sealed by Host/Sealing.swift), and takes in everyone else's, merged as
// all changes are: a record is written once and never over, so nothing anyone does is lost.
// Pictures and named versions go and come the same way. Reading the room is the shared
// `CloudRoom.fetch` (Model/RelayRooms.swift); what is here is the Mac's bookkeeping around it.
//
// What this computer has done with the room is kept in its own folder in the design,
// `cloud.json`, after the changes it took in are in the design's parts.

final class CloudCopy {
    let keys: ShareKeys
    let replica: String
    /// Who works on the design, as their records say.
    private(set) var people: [String: FolderShare.Person] = [:]
    /// Why the relay could not be reached, until it can.
    private(set) var problem: String?

    private weak var session: SharedSession?
    private var progress = CloudRoom.Progress()
    private var listedFully = false
    private var syncing = false
    private var again = false
    private var stopped = false
    private var waiting: Task<Void, Never>?
    private var timer: Timer?
    /// Changes the live room brought, which their makers send too; sent from here as well.
    private var relayedChanges: [SharedDesign] = []
    /// The pictures the design shows.
    private var shown: Set<String> = []
    /// Pictures asked the room for and not there yet, with when.
    private var asked: [String: Date] = [:]

    init(keys: ShareKeys, replica: String) {
        self.keys = keys
        self.replica = replica
    }

    var sentUpTo: Int64 { progress.sentUpTo }

    // MARK: Opening and closing

    func start(for session: SharedSession) {
        self.session = session
        stopped = false
        progress = Self.progress(of: session.url, replica: replica) ?? CloudRoom.Progress()
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
        session?.unshared(own: Linking.owns(keys.room))
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

    /// Sends and receives now, once whatever is going on is done: for the headless checks, and
    /// when the design is closed.
    func syncNow() async {
        while syncing { try? await Task.sleep(for: .milliseconds(5)) }
        waiting?.cancel()
        await sync()
    }

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
        guard let session, let server = Linking.server, !stopped else { return }
        do {
            try await send(session, server)
            try await receive(session, server)
            if problem != nil {
                problem = nil
                WindowsCore.tellShareNews()
            }
        } catch ShareError.gone {
            gone()
        } catch {
            NSLog("Bezzle: room %@: %@", String(keys.room.prefix(8)), "\(error)")
            let now = String(localized: "Bezzle cannot connect right now. Your changes are kept and go out once it can.")
            if problem != now {
                problem = now
                WindowsCore.tellShareNews()
            }
        }
    }

    // MARK: Sending

    /// Sends everything there is to send, pictures counted as they go: before a link is handed out.
    func sendEverything(progress report: @escaping (Int, Int) -> Void) async throws {
        guard let session, let server = Linking.server else { throw ShareError.unreachable }
        if let doc = WindowsCore.previewBase ?? WindowsCore.design { shown.formUnion(SharedSession.pictures(in: doc.nodes)) }
        try await send(session, server, report: report)
        for version in WindowsCore.versions.kept where version.isNamed && version.shared == true {
            if let data = try? Data(contentsOf: FolderShare.versionFile(version.id, of: session.url)) {
                try await sendVersion(version, data: data, to: server)
            }
        }
    }

    func sendMeta(_ meta: ShareMeta) async throws {
        guard let server = Linking.server, let owner = Linking.ownerToken(for: keys.room),
              let data = FolderShare.encode(meta), let sealed = keys.seal(data, about: ShareRecord.meta.key) else { throw ShareError.unreachable }
        try await server.put(keys.room, ShareRecord.meta.key, sealed, write: keys.writeToken, writer: nil, owner: owner)
    }

    /// A version named here, for everyone.
    func sendVersion(_ version: DesignVersion, data: Data) {
        guard let server = Linking.server else { return }
        Task {
            do { try await sendVersion(version, data: data, to: server) } catch {
                NSLog("Bezzle could not send a version: %@", "\(error)")
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

    /// Sends what was changed here since this computer's last record, with what the live room
    /// brought, and now and then the whole design; then pictures not there yet, and who this is.
    private func send(_ session: SharedSession, _ server: ShareServer, report: ((Int, Int) -> Void)? = nil) async throws {
        // What goes is kept here first.
        session.persist()
        let state = session.state
        var changes = state.changes(by: replica, after: progress.sentUpTo)
        let relayed = relayedChanges
        for design in relayed { changes.merge(design) }
        var own = progress.parts.compactMap { FolderShare.Part.record($0)?.part }
        let writer = Linking.writer(for: keys.room)
        // The owner's first: the whole design, for everyone who comes to start from.
        let first = own.isEmpty && Linking.owns(keys.room)
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
        try await sendPictures(session, server, report: report)
        let me = FolderCopy.me(replica: replica, since: progress.introduced?.since ?? WindowsCore.nowMilliseconds)
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

    private func sendPictures(_ session: SharedSession, _ server: ShareServer, report: ((Int, Int) -> Void)?) async throws {
        let images = session.url.appendingPathComponent("images", isDirectory: true)
        let names = shown.subtracting(progress.pictures).filter { FileManager.default.fileExists(atPath: images.appendingPathComponent($0).path) }.sorted()
        report?(0, names.count)
        for (i, name) in names.enumerated() {
            let key = ShareRecord.picture(keys.pictureName(name)).key
            if progress.known[key] == nil {
                guard let sealed = await Self.seal(file: images.appendingPathComponent(name), keys, about: key) else { continue }
                do {
                    try await server.put(keys.room, key, sealed, write: keys.writeToken, writer: nil, owner: nil)
                } catch ShareError.refused(413) {
                    NSLog("Bezzle: a picture is too large for the relay: %@", name)
                }
            }
            progress.pictures.insert(name)
            report?(i + 1, names.count)
            if i % 8 == 7 { keepProgress() }
        }
        if !names.isEmpty { keepProgress() }
    }

    // MARK: Receiving

    private func receive(_ session: SharedSession, _ server: ShareServer) async throws {
        let fetched = try await CloudRoom.fetch(keys, from: server, progress: progress, fully: !listedFully, replica: replica)
        listedFully = true
        progress = fetched.progress
        if fetched.again { again = true }
        for (who, person) in fetched.people where people[who] != person { people[who] = person }
        if let meta = fetched.meta, var link = session.link, !link.ended,
           link.title != meta.title || link.ownerName != meta.owner {
            link.title = meta.title
            link.ownerName = meta.owner
            try? Linking.write(link, to: session.url)
            session.retitled(link)
        }
        if !fetched.changes.isEmpty {
            // What was done here is taken in first, from the design in front only when it is this one.
            session.receive(fetched.changes, from: .cloud, current: WindowsCore.sharing === session ? WindowsCore.previewBase ?? WindowsCore.design : nil)
            session.persist()
        }
        keepProgress()
        if WindowsCore.sharing === session {
            for version in fetched.versions where !WindowsCore.versions.kept.contains(where: { $0.id == version.id && $0.name == version.name }) {
                var data = try? Data(contentsOf: FolderShare.versionFile(version.id, of: session.url))
                if data == nil {
                    let key = ShareRecord.versionDesign(version.id).key
                    data = try await server.get(keys.room, key, read: keys.readToken).flatMap { keys.open($0, about: key) }
                }
                if let data { WindowsCore.versions.arrived(version, data: data) }
            }
        }
        try await fetchPictures(session, server)
    }

    /// Pictures the design shows that are not here yet, from the room.
    private func fetchPictures(_ session: SharedSession, _ server: ShareServer) async throws {
        let design = session.url, images = design.appendingPathComponent("images", isDirectory: true)
        let wanted = shown.isEmpty ? SharedSession.pictures(in: session.state.flatDesign().document().nodes) : shown
        // In a synced folder whoever placed a picture writes it into the design, and the folder
        // brings it: one from the room waits beside it (`WindowsCore.arrivals`), as written in by
        // every computer it was kept once for each.
        let synced = SyncedPlaces.service(of: design) != nil
        for name in wanted.sorted() where WindowsCore.arrivals.picture(name, of: design) == nil {
            guard !name.hasPrefix("."), (name as NSString).lastPathComponent == name else { continue }
            let key = ShareRecord.picture(keys.pictureName(name)).key
            if let last = asked[name], Date().timeIntervalSince(last) < 20 { continue }
            asked[name] = Date()
            guard progress.known[key] != nil, let sealed = try await server.get(keys.room, key, read: keys.readToken),
                  let data = await Self.open(file: sealed, keys, about: key) else { continue }
            do {
                if synced {
                    try WindowsCore.arrivals.keep(data, as: name, in: WindowsCore.arrivals.images(of: design))
                } else {
                    try WindowsCore.makeFolder(images, in: design)
                    try data.write(to: images.appendingPathComponent(name), options: .atomic)
                }
            } catch {
                NSLog("Bezzle could not keep a picture: %@", "\(error)")
                continue
            }
            asked[name] = nil
            progress.pictures.insert(name)
            if WindowsCore.sharing === session { WindowsCore.pictureArrived(name, in: design) }
        }
    }

    // MARK: Keeping what was done

    private static func progressFile(_ design: URL, _ replica: String) -> URL {
        FolderShare.folder(of: replica, in: design).appendingPathComponent("cloud.json")
    }

    static func progress(of design: URL, replica: String) -> CloudRoom.Progress? {
        (try? Data(contentsOf: progressFile(design, replica))).flatMap { FolderShare.decode(CloudRoom.Progress.self, from: $0) }
    }

    /// Keeps what was done with the room, after what was taken in.
    static func keep(_ progress: CloudRoom.Progress, of design: URL, replica: String) {
        let file = progressFile(design, replica)
        guard let data = FolderShare.encode(progress), (try? WindowsCore.makeFolder(file.deletingLastPathComponent(), in: design)) != nil else { return }
        try? data.write(to: file, options: .atomic)
    }

    private func keepProgress() {
        guard let url = session?.url else { return }
        Self.keep(progress, of: url, replica: replica)
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
