import AppKit
import CoreServices
import Observation

/// Folders that the computers of those working in them keep in step: Google Drive, Dropbox,
/// OneDrive and the like, iCloud Drive, or a server's. A design kept in one is shared through it
/// (see `FolderShare`), with everyone the folder is shared with.
nonisolated enum SyncedFolders {
    /// The person's home folder, also in the sandbox, where `NSHomeDirectory` is the container's.
    static let home: String = {
        if let entry = getpwuid(getuid()), let dir = entry.pointee.pw_dir { return String(cString: dir) }
        return NSHomeDirectory()
    }()

    /// Where macOS keeps the folders of Google Drive, Dropbox, OneDrive and the like.
    static var storage: URL { URL(fileURLWithPath: home).appendingPathComponent("Library/CloudStorage", isDirectory: true) }

    #if DEBUG
    /// Folders treated as synced in tests, with the service each stands for.
    nonisolated(unsafe) static var forTests: [String: String] = [:]
    #endif

    /// The service that keeps the folder holding `design` in step with other computers, by name;
    /// nil when it is on this Mac alone.
    static func service(of design: URL) -> String? {
        let folder = design.standardizedFileURL.deletingLastPathComponent()
        let path = folder.resolvingSymlinksInPath().path
        func inside(_ prefix: String) -> Bool { path == prefix || path.hasPrefix(prefix.hasSuffix("/") ? prefix : prefix + "/") }
        #if DEBUG
        for (prefix, name) in forTests where inside(URL(fileURLWithPath: prefix).resolvingSymlinksInPath().path) { return name }
        if let synced = ProcessInfo.processInfo.environment["BEZZLE_SYNCED_FOLDER"], !synced.isEmpty,
           inside(URL(fileURLWithPath: synced).resolvingSymlinksInPath().path) { return "Google Drive" }
        #endif
        let storage = storage.path + "/"
        if path.hasPrefix(storage) {
            return name(ofStorage: path.dropFirst(storage.count).split(separator: "/").first.map(String.init) ?? "")
        }
        if inside(home + "/Library/Mobile Documents") { return "iCloud Drive" }
        let values = try? folder.resourceValues(forKeys: [.isUbiquitousItemKey, .volumeIsLocalKey, .volumeLocalizedNameKey])
        if values?.isUbiquitousItem == true { return "iCloud Drive" }
        if values?.volumeIsLocal == false { return values?.volumeLocalizedName ?? folder.lastPathComponent }
        return nil
    }

    /// A service's name from its folder in CloudStorage: "GoogleDrive-erik@example.com" is Google Drive.
    static func name(ofStorage folder: String) -> String {
        let base = folder.split(separator: "-", maxSplits: 1).first.map(String.init) ?? folder
        switch base.lowercased() {
        case "googledrive": return "Google Drive"
        case "onedrive": return "OneDrive"
        case "dropbox": return "Dropbox"
        case "box": return "Box"
        default: return base.isEmpty ? folder : base
        }
    }

    /// Whether the service keeps a design's package as one item, whatever is written in it, as
    /// iCloud Drive does; the others (Google Drive, OneDrive, Dropbox) keep each file in it as an
    /// item of its own, and keep two files of one name side by side when two computers write one.
    static func keepsPackagesWhole(_ service: String) -> Bool { service == "iCloud Drive" }

    /// The services on this Mac with a folder of their own, Google Drive first, to move a design into.
    static func places() -> [(name: String, url: URL)] {
        let found = (try? FileManager.default.contentsOfDirectory(at: storage, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        return found.map { (name(ofStorage: $0.lastPathComponent), $0) }
            .sorted { a, b in (a.name == "Google Drive") != (b.name == "Google Drive") ? a.name == "Google Drive" : a.name < b.name }
    }
}

/// Keeps a shared design's parts in its package, as `FolderShare` lays them out: this Mac's own
/// changes, and those it took in from the relay, in files in its own folder there, and now and
/// then the whole design. Every shared design keeps them, so that it opens as it is shared, also
/// with no network. One kept in a folder that Google Drive, Dropbox or the like keep in step
/// also takes in everyone else's files there as the folder brings them, so that several people
/// can have it open at once and nothing anyone does is lost or put over someone else's.
@Observable
final class FolderSync {
    /// Everyone else whose files are in the design, this Mac's other selves among them, as their
    /// files say who they are.
    private(set) var people: [FolderShare.Person] = []
    /// The secret of the folder's live room, which everyone with the folder has.
    private(set) var room: FolderShare.Room
    /// The service keeping the folder in step, as the window names it; nil on this Mac alone.
    private(set) var service: String?

    @ObservationIgnored private(set) var url: URL
    @ObservationIgnored let replica: String
    /// The latest of this Mac's changes its files hold.
    @ObservationIgnored private(set) var writtenUpTo: Int64
    /// This Mac's own files of changes and wholes, by name.
    @ObservationIgnored private var own: [String]
    @ObservationIgnored private var seen: Seen
    @ObservationIgnored private weak var collaboration: Collaboration?
    @ObservationIgnored private var watch: FolderWatch?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var looking = false
    @ObservationIgnored private var lookAgain = false
    @ObservationIgnored private(set) lazy var roomKeys: ShareKeys = Self.keys(of: room)

    /// What has been read of everyone else's files, so that each is read once.
    typealias Seen = FolderShare.Seen
    /// What a look through the folder found.
    typealias Found = FolderShare.Found

    private init(url: URL, replica: String, room: FolderShare.Room, seen: Seen, own: [String], writtenUpTo: Int64) {
        self.url = url
        self.replica = replica
        self.room = room
        self.seen = seen
        self.own = own
        self.writtenUpTo = writtenUpTo
        service = SyncedFolders.service(of: url)
        people = Self.sorted(seen.people)
    }

    private static func keys(of room: FolderShare.Room) -> ShareKeys {
        Data(hex: room.seed).flatMap(ShareKeys.init(secret:)) ?? ShareKeys(secret: ShareKeys.newSecret())!
    }

    // MARK: Where everything is

    nonisolated static func peopleFolder(of design: URL) -> URL { FolderShare.people(of: design) }

    nonisolated static func folder(of replica: String, in design: URL) -> URL { FolderShare.folder(of: replica, in: design) }

    private nonisolated static func roomFile(_ design: URL) -> URL { FolderShare.roomURL(of: design) }

    /// The folder room the design at `design` is shared in, if any.
    nonisolated static func room(of design: URL) -> FolderShare.Room? { FolderShare.room(of: design) }

    /// Whether a design keeps its changes in parts: one in a synced folder, or one that has been
    /// or is shared, whose parts go on being written wherever it is, so that none of what is done
    /// to it meanwhile is missing should it go back.
    nonisolated static func applies(to design: URL) -> Bool {
        guard DesignFile.isPackage(design) else { return false }
        return isShared(design) || SyncedFolders.service(of: design) != nil
    }

    /// Whether the design has people's files in it.
    nonisolated static func isShared(_ design: URL) -> Bool { FolderShare.isShared(design) }

    // MARK: Opening

    /// The design as everyone's files have it, with what is needed to keep it in step. The first
    /// time, there being no files yet, the design starts from `seed`, as when it has just come from
    /// the relay, or else from its own file (see `FolderShare.first`).
    static func open(_ url: URL, replica: String, seed: SharedDesign? = nil) -> (sync: FolderSync, state: SharedDesign)? {
        let mine = folder(of: replica, in: url)
        do {
            // In the design while it is there, never its package made anew: one made again while a
            // sync service had it away for a moment is a second design of the same name to it.
            try DesignFile.makeFolder(mine, in: url)
        } catch {
            NSLog("Bezzle could not make room for its files in %@: %@", url.path, error.localizedDescription)
            return nil
        }
        let found = look(url, replica: replica, seen: Seen(), opening: true)
        let opened = FolderShare.opening(found, seed: seed, file: {
            guard let doc = try? DesignFile.read(url) else { return nil }
            let file = url.appendingPathComponent(DesignFile.documentName)
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? Date()
            return (doc, Int64(modified.timeIntervalSince1970 * 1000))
        }, by: replica)
        let state = opened.state, own = opened.own, writtenUpTo = opened.writtenUpTo
        if let whole = opened.first {
            guard let data = FolderShare.pack(state), (try? data.write(to: mine.appendingPathComponent(whole.fileName), options: .atomic)) != nil else {
                NSLog("Bezzle could not write the first of its files in %@", url.path)
                return nil
            }
        }
        var room = found.seen.room
        if room?.isValid != true || !claim(room!, at: url) {
            // None yet, or this is a copy of the design made in the Finder, which is a design of its
            // own, with a room of its own.
            let fresh = FolderShare.Room.fresh(at: Collaboration.now)
            if let data = FolderShare.encode(fresh) { _ = try? DesignFile.coordinated(writing: url) { _ in try data.write(to: roomFile(url), options: .atomic) } }
            _ = claim(fresh, at: url)
            room = fresh
        }
        var seen = found.seen
        seen.room = room
        let sync = FolderSync(url: url, replica: replica, room: room!, seen: seen, own: own, writtenUpTo: writtenUpTo)
        sync.introduce(since: Collaboration.now)
        return (sync, state)
    }

    /// Each folder room's design on this Mac, by its secret, to tell a copy made in the Finder.
    private static var rooms: [String: String] {
        get { Library.settings.dictionary(forKey: "folderRooms") as? [String: String] ?? [:] }
        set { Library.settings.set(newValue, forKey: "folderRooms") }
    }

    /// Whether the design at `url` is this Mac's design with `room`, rather than a copy of one
    /// that is still there.
    private static func claim(_ room: FolderShare.Room, at url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        if let known = rooms[room.seed], known != path, FileManager.default.fileExists(atPath: known),
           FileManager.default.fileExists(atPath: roomFile(URL(fileURLWithPath: known)).path) { return false }
        rooms[room.seed] = path
        return true
    }

    /// Who this Mac last said it was, in its `me.json`.
    @ObservationIgnored private var introduced: FolderShare.Person?

    /// Says who works on the design from this Mac, when that is new or has changed.
    private func introduce(since: Int64? = nil) {
        let file = Self.folder(of: replica, in: url).appendingPathComponent(FolderShare.personFile)
        if introduced == nil {
            introduced = (try? Data(contentsOf: file)).flatMap { FolderShare.decode(FolderShare.Person.self, from: $0) }
        }
        let me = Self.me(replica: replica, since: introduced?.since ?? since ?? Collaboration.now)
        guard introduced != me, let data = FolderShare.encode(me) else { return }
        introduced = me
        let design = url
        DocumentStore.saving.async { _ = try? DesignFile.coordinated(writing: design) { _ in try data.write(to: file, options: .atomic) } }
    }

    /// Who works from this Mac, by its name.
    static func me(replica: String, since: Int64 = 0) -> FolderShare.Person {
        FolderShare.Person(replica: replica, name: LiveRoom.myName, app: "mac", since: since)
    }

    // MARK: Keeping in step

    func start(for collaboration: Collaboration) {
        self.collaboration = collaboration
        watch?.stop()
        timer?.invalidate()
        timer = nil
        // Only a design in a folder others write in too has anything to look for.
        guard service != nil || !people.isEmpty else { return }
        watch = FolderWatch(paths: [url.path]) { [weak self] in self?.lookSoon() }
        // A folder on a server tells nothing of what others write in it, and a sync service
        // may now and then not either: looked through every so often all the same.
        let local = (try? url.resourceValues(forKeys: [.volumeIsLocalKey]))?.volumeIsLocal ?? true
        let timer = Timer(timeInterval: local ? 20 : 5, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.lookSoon() } }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        watch?.stop()
        watch = nil
        timer?.invalidate()
        timer = nil
        collaboration = nil
    }

    func moved(to url: URL) {
        self.url = url
        _ = Self.claim(room, at: url)
        service = SyncedFolders.service(of: url)
        guard let collaboration else { return }
        start(for: collaboration)
        collaboration.refreshMark()
    }

    /// Looks through the folder for what is new from the others, away from the main thread.
    func lookSoon() {
        // Renamed or moved, as by someone else in the folder: the design goes on where it is now.
        if !DesignFile.exists(url) { collaboration?.store?.follow() }
        guard !looking else {
            lookAgain = true
            return
        }
        looking = true
        let url = url, replica = replica, seen = seen
        // A copy the folder's service made beside it, written on another computer as this one
        // wrote: taken in first, so that what it brings is read now. And, in a service that keeps
        // each file apart, the copies it made inside it as two computers wrote one name.
        let synced = service != nil, open = Self.openHere()
        let inside = service.map { !SyncedFolders.keepsPackagesWhole($0) } ?? false
        let using = inside ? (collaboration?.store.map { Collaboration.pictures(in: $0.sharedDoc) } ?? []) : []
        DispatchQueue.global(qos: .utility).async {
            if synced { Self.foldCopies(beside: url, open: open) }
            if inside { Self.foldCopiesInside(url, using: using) }
            let found = Self.look(url, replica: replica, seen: seen, opening: false)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.looking = false
                if self.url == url { self.take(found) }
                if self.lookAgain {
                    self.lookAgain = false
                    self.lookSoon()
                }
            }
        }
    }

    /// The designs open here, by path.
    static func openHere() -> Set<String> {
        Set(Tabs.shared.designs.compactMap { $0.store?.url.standardizedFileURL.path })
    }

    #if DEBUG
    /// Looks through the folder at once, for tests, on behalf of `collaboration`.
    func lookForTesting(for collaboration: Collaboration) {
        self.collaboration = collaboration
        take(Self.look(url, replica: replica, seen: seen, opening: false))
    }
    #endif

    private func take(_ found: Found) {
        seen = found.seen
        if found.peopleChanged {
            let now = Self.sorted(seen.people)
            if now != people { people = now }
            collaboration?.refreshMark()
        }
        if let room = found.seen.room, room.isValid, room != self.room {
            self.room = room
            roomKeys = Self.keys(of: room)
            _ = Self.claim(room, at: url)
            collaboration?.roomChanged()
        }
        if !found.changes.isEmpty, let collaboration {
            collaboration.receive(found.changes, from: .folder)
            // In a synced folder, what came from the relay meanwhile is kept with this Mac's next
            // own change, or as the design is closed: a Mac only looking on writes nothing in it.
            if service == nil { collaboration.persist() }
        }
        let store = collaboration?.store
        if !found.pictures.isEmpty { Arrivals.arrived(pictures: found.pictures, of: url) }
        for name in found.pictures {
            store?.pictureArrived(name)
            collaboration?.live?.arrived(name)
        }
        for (version, data) in found.versions { store?.versions.arrived(version, data: data) }
    }

    /// Writes what was changed here since this Mac's last file, with what came from elsewhere than
    /// the folder (`kept`), and now and then the whole design as this Mac has it, on the queue the
    /// design is saved on and ahead of its own file.
    func persist(_ state: SharedDesign, keeping kept: [SharedDesign] = []) {
        introduce()
        guard let writing = FolderShare.writing(state, by: replica, since: writtenUpTo, keeping: kept, own: own) else { return }
        let from = writtenUpTo
        writtenUpTo = state.clock.time
        own = writing.names
        let design = url, folder = Self.folder(of: replica, in: url)
        DocumentStore.saving.async {
            do {
                try DesignFile.coordinated(writing: design) { _ in
                    try DesignFile.makeFolder(folder, in: design)
                    try FolderShare.write(writing, into: folder)
                }
            } catch {
                NSLog("Bezzle could not write its changes to %@: %@", folder.path, error.localizedDescription)
                // Written again with the next save.
                DispatchQueue.main.async { [weak self] in self?.unwritten(since: from, folder: folder) }
            }
        }
    }

    private func unwritten(since time: Int64, folder: URL) {
        writtenUpTo = min(writtenUpTo, time)
        own = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).filter { FolderShare.Part(fileName: $0) != nil }
    }

    // MARK: How it is shared

    /// The others, apart from this Mac's own other selves.
    var others: [FolderShare.Person] {
        let me = Self.me(replica: replica)
        return people.filter { !$0.isSamePerson(as: me) }
    }

    var mark: SharingMark? {
        guard let service, !others.isEmpty else { return nil }
        return .inFolder(service)
    }

    /// How a design not open is shared through its folder, for the home screen.
    static func mark(of url: URL) -> SharingMark? {
        guard isShared(url), let service = SyncedFolders.service(of: url) else { return nil }
        let me = me(replica: Sharing.replica)
        let folders = (try? FileManager.default.contentsOfDirectory(at: peopleFolder(of: url), includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        let others = folders.contains { dir in
            guard dir.lastPathComponent != me.replica else { return false }
            guard let data = try? Data(contentsOf: dir.appendingPathComponent(FolderShare.personFile)),
                  let person = FolderShare.decode(FolderShare.Person.self, from: data) else { return false }
            return !person.isSamePerson(as: me)
        }
        return others ? .inFolder(service) : nil
    }

    /// A design not open as everyone's files in it have it; nil when none would open.
    nonisolated static func document(of url: URL) -> BezzleDocument? { FolderShare.document(of: url) }

    private static func sorted(_ people: [String: FolderShare.Person]) -> [FolderShare.Person] {
        people.values.sorted { $0.since != $1.since ? $0.since < $1.since : $0.replica < $1.replica }
    }

    // MARK: Copies the folder's service made

    /// The copies the folder's service made beside the design at `design` as it kept the design
    /// written on two computers at once, as it does with a design that is one item to it ("Poster
    /// 2", "Poster (1)"); see `FolderShare.copiesFromTheService`. Only in a folder a service keeps
    /// in step.
    nonisolated static func copiesFromTheService(of design: URL) -> [URL] {
        guard SyncedFolders.service(of: design) != nil else { return [] }
        return FolderShare.copiesFromTheService(of: design)
    }

    /// Takes what a copy the folder's service made holds into the design and puts the copy away
    /// (`discard`, the Trash), each held by the system's file coordination as it is written
    /// (`FolderShare.fold`).
    nonisolated static func fold(_ copy: URL, into design: URL,
                                 discard: (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }) throws {
        try FolderShare.fold(copy, into: design, holding: { url, write in try DesignFile.coordinated(writing: url) { _ in try write() } }, discard: discard)
    }

    /// Takes back in the copies the folder's service made inside the design, as two computers
    /// wrote the same name in it (`FolderShare.foldCopiesInside`), but pictures it shows by such a
    /// name (`using`). Held by the system's file coordination; what is put away goes in the Trash.
    @discardableResult
    nonisolated static func foldCopiesInside(_ design: URL, using: Set<String>) -> [String] {
        let taken = FolderShare.foldCopiesInside(design, using: using, holding: { url, write in try DesignFile.coordinated(writing: url) { _ in try write() } },
                                                 discard: { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) })
        if !taken.isEmpty {
            NSLog("Bezzle took back into %@ what the folder's sync service kept twice in it: %@", design.lastPathComponent, taken.joined(separator: ", "))
        }
        return taken
    }

    /// Folds every copy the folder's service made beside the design into it, but those open here
    /// (`open`, by path). True when any was.
    @discardableResult
    nonisolated static func foldCopies(beside design: URL, open: Set<String>,
                                       discard: (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }) -> Bool {
        var folded = false
        for copy in copiesFromTheService(of: design) where !open.contains(copy.standardizedFileURL.path) {
            do {
                try fold(copy, into: design, discard: discard)
                folded = true
                NSLog("Bezzle took %@ into %@, a copy the folder's sync service made of it, and put it in the Trash", copy.lastPathComponent, design.lastPathComponent)
            } catch {
                NSLog("Bezzle could not take %@ into %@: %@", copy.path, design.path, error.localizedDescription)
            }
        }
        return folded
    }

    // MARK: Reading the folder

    /// Reads what is new in the folder since `seen`: others' changes, who they are, the room,
    /// pictures that came, and versions others named. Opening, this Mac's own files are read too,
    /// as the design is made from everyone's.
    nonisolated static func look(_ url: URL, replica: String, seen: Seen, opening: Bool) -> Found {
        FolderShare.look(url, replica: replica, seen: seen, opening: opening)
    }
}

/// Tells when anything changes in or under some folders, or one of them is renamed or moved,
/// on the main thread.
nonisolated final class FolderWatch: @unchecked Sendable {
    private var stream: FSEventStreamRef?
    private let changed: @MainActor () -> Void

    init(paths: [String], changed: @escaping @MainActor () -> Void) {
        self.changed = changed
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            let watch = Unmanaged<FolderWatch>.fromOpaque(info).takeUnretainedValue()
            MainActor.assumeIsolated { watch.changed() }
        }
        guard let stream = FSEventStreamCreate(nil, callback, &context, paths as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.5,
                                               FSEventStreamCreateFlags(kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagWatchRoot)) else { return }
        FSEventStreamSetDispatchQueue(stream, .main)
        FSEventStreamStart(stream)
        self.stream = stream
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    deinit { stop() }
}
