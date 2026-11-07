import Foundation

/// A shared design's parts in its package (see `FolderShare`), read and written as every copy of
/// Bezzle reads and writes them: the Mac's `FolderSync` and Bezzle for Windows both call these,
/// so that each keeps its own files the same way and reads everyone else's the same way. Only
/// files and the parts' own rules are here; watching the folder, telling a copy of a design made
/// in the Finder or Explorer, and when to write are each platform's.
nonisolated extension FolderShare {
    /// The folder in a design's package that sharing keeps its files in (`SharingFiles`).
    static let sharingFolder = "sharing"

    static func sharing(of design: URL) -> URL { design.appendingPathComponent(sharingFolder, isDirectory: true) }

    /// The folder of people, with a folder of files for each computer.
    static func people(of design: URL) -> URL { sharing(of: design).appendingPathComponent(peopleFolder, isDirectory: true) }

    /// The folder of files only the computer with `replica` writes.
    static func folder(of replica: String, in design: URL) -> URL { people(of: design).appendingPathComponent(replica, isDirectory: true) }

    /// Where the secret of a design's folder room is kept.
    static func roomURL(of design: URL) -> URL { sharing(of: design).appendingPathComponent(roomFile) }

    /// Whether the design has people's files in it.
    static func isShared(_ design: URL) -> Bool {
        FileManager.default.fileExists(atPath: people(of: design).path)
    }

    /// The folder room the design at `design` is shared in, if any.
    static func room(of design: URL) -> Room? {
        (try? Data(contentsOf: roomURL(of: design))).flatMap { decode(Room.self, from: $0) }
    }

    // MARK: Reading everyone's files

    /// What has been read of everyone else's files, so that each is read once.
    struct Seen: Sendable {
        var read: [String: Set<String>] = [:]
        var failed: [String: Set<String>] = [:]
        var people: [String: Person] = [:]
        var room: Room?
        var pictures: Set<String> = []
        /// When each person's list of versions was last read, as its file was then.
        var versions: [String: Date] = [:]
    }

    /// What a look through the folder found.
    struct Found: Sendable {
        var seen: Seen
        var changes: [SharedDesign] = []
        var peopleChanged = false
        var pictures: [String] = []
        var versions: [(DesignVersion, Data)] = []
        /// How many of everyone's files of changes and wholes there are, this computer's own among them.
        var parts = 0
        /// This computer's own, by name.
        var own: [String] = []
    }

    /// Reads what is new in the folder since `seen`: others' changes, who they are, the room,
    /// pictures that came, and versions others named. Opening, this computer's own files are read
    /// too, as the design is made from everyone's.
    static func look(_ url: URL, replica: String, seen: Seen, opening: Bool) -> Found {
        let fm = FileManager.default
        var found = Found(seen: seen)
        let dirs = (try? fm.contentsOfDirectory(at: people(of: url), includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
        for dir in dirs where (try? dir.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
            let who = dir.lastPathComponent
            let names = ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).filter { Part(fileName: $0) != nil }
            found.parts += names.count
            if who == replica {
                found.own = names
                if !opening { continue }
            } else if let data = try? Data(contentsOf: dir.appendingPathComponent(personFile)),
                      let person = decode(Person.self, from: data), found.seen.people[who] != person {
                found.seen.people[who] = person
                found.peopleChanged = true
            }
            let read = Set((found.seen.read[who] ?? []).compactMap(Part.init(fileName:)))
            let failed = Set((found.seen.failed[who] ?? []).compactMap(Part.init(fileName:)))
            for part in toRead(parts(files: names), read: read, failed: failed) {
                // Reading it brings it down, if the service keeps it in the cloud until wanted.
                if let data = try? Data(contentsOf: dir.appendingPathComponent(part.fileName)), let design = unpack(data) {
                    found.changes.append(design)
                    found.seen.read[who, default: []].insert(part.fileName)
                    found.seen.failed[who]?.remove(part.fileName)
                } else {
                    // Still on its way, most likely: tried again next time.
                    found.seen.failed[who, default: []].insert(part.fileName)
                }
            }
            if who != replica { lookAtVersions(in: dir, of: who, design: url, found: &found, opening: opening) }
        }
        if let data = try? Data(contentsOf: roomURL(of: url)), let room = decode(Room.self, from: data), room.isValid {
            found.seen.room = room
        }
        let images = url.appendingPathComponent(imagesFolder, isDirectory: true)
        let pictures = Set(((try? fm.contentsOfDirectory(atPath: images.path)) ?? []).filter { !$0.hasPrefix(".") })
        if opening {
            found.seen.pictures = pictures
        } else {
            for name in pictures.subtracting(found.seen.pictures) {
                // Read once here, so it is on this computer before it is drawn.
                guard (try? Data(contentsOf: images.appendingPathComponent(name)))?.isEmpty == false else { continue }
                found.pictures.append(name)
                found.seen.pictures.insert(name)
            }
        }
        return found
    }

    /// Versions someone else named since their list was last read, with what each holds.
    private static func lookAtVersions(in dir: URL, of who: String, design: URL, found: inout Found, opening: Bool) {
        let file = dir.appendingPathComponent(versionsFile)
        guard let date = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
              found.seen.versions[who] != date else { return }
        found.seen.versions[who] = date
        // An open design's shelf reads everyone's when it first shows them.
        guard !opening else { return }
        for version in versionList(at: file) where version.isNamed && version.shared == true {
            guard let data = try? Data(contentsOf: versionFile(version.id, of: design)) else {
                // Its file is not here yet: looked for again next time.
                found.seen.versions[who] = nil
                continue
            }
            found.versions.append((version, data))
        }
    }

    /// A design not open as everyone's files in it have it; nil when none would open.
    static func document(of url: URL) -> BezzleDocument? {
        let found = look(url, replica: "", seen: Seen(), opening: true)
        guard !found.changes.isEmpty else { return nil }
        var state = SharedDesign()
        for design in found.changes { state.merge(design) }
        return state.flatDesign().document()
    }

    // MARK: Opening

    /// The design as it opens, from everyone's files as a first look found them.
    struct Opening: Sendable {
        var state: SharedDesign
        /// This computer's own files, by name, and the latest of its changes they hold.
        var own: [String]
        var writtenUpTo: Int64
        /// The first of this computer's files, to be written with the state before anything else:
        /// there being no files yet, the design starts from `seed` or from its own file.
        var first: Part?
    }

    /// The design as everyone's files have it. The first time, there being no files yet, it starts
    /// from `seed`, as when it has just come from the relay, or else from its own file, as `file`
    /// gives it with the time it was written (milliseconds since 1970; see `first`).
    static func opening(_ found: Found, seed: SharedDesign?, file: () -> (doc: BezzleDocument, modified: Int64)?, by replica: String) -> Opening {
        var state = SharedDesign()
        for design in found.changes { state.merge(design) }
        var opened = Opening(state: state, own: found.own, writtenUpTo: parts(files: found.own).last?.upTo ?? 0)
        if found.parts == 0 {
            // The first to share it, or the first since it came into the folder.
            if let seed, !seed.isEmpty {
                opened.state.merge(seed)
            } else if let own = file() {
                opened.state.merge(first(own.doc, modified: own.modified, by: replica))
            }
            let whole = Part(.whole, upTo: nextUpTo(opened.state.clock.time, after: []))
            opened.own = [whole.fileName]
            opened.writtenUpTo = opened.state.clock.time
            opened.first = whole
        } else if opened.state.isEmpty, let own = file() {
            // Everyone's files are there, but none would open yet: the design opens as its own
            // file last had it, at the earliest of times, so that each change in theirs wins once
            // it comes, and what is done here meanwhile is kept as anything done here is.
            opened.state.merge(first(own.doc, modified: 1, by: replica))
        }
        return opened
    }

    // MARK: Writing one's own

    /// What a computer writes of its own: its files by name after the writing, what goes into
    /// which, and which of its files go.
    struct Writing: Sendable {
        var names: [String]
        var writes: [(name: String, design: SharedDesign)]
        var gone: [String]
    }

    /// What `replica` writes of `state`: what it changed since its files last held (`writtenUpTo`),
    /// with what came from elsewhere than the folder (`kept`), and now and then the whole design
    /// as it has it, folding its older files away. Nil when there is nothing to write.
    static func writing(_ state: SharedDesign, by replica: String, since writtenUpTo: Int64, keeping kept: [SharedDesign], own: [String]) -> Writing? {
        var changes = state.changes(by: replica, after: writtenUpTo)
        for design in kept { changes.merge(design) }
        let upTo = nextUpTo(state.clock.time, after: parts(files: own))
        var names = own
        var writes: [(name: String, design: SharedDesign)] = []
        if !changes.isEmpty {
            let part = Part(.changes, upTo: upTo)
            names.append(part.fileName)
            writes.append((part.fileName, changes))
        }
        var gone: [String] = []
        if !writes.isEmpty, shouldFold(parts(files: names)) {
            let whole = Part(.whole, upTo: upTo)
            names.append(whole.fileName)
            writes.append((whole.fileName, state))
            gone = folded(parts(files: names), into: upTo).map(\.fileName)
            names.removeAll { gone.contains($0) }
        }
        guard !writes.isEmpty else { return nil }
        return Writing(names: names, writes: writes, gone: gone)
    }

    /// Writes them into the computer's own folder, which is there.
    static func write(_ writing: Writing, into folder: URL) throws {
        for (name, design) in writing.writes {
            guard let data = pack(design) else { throw CocoaError(.fileWriteUnknown) }
            try data.write(to: folder.appendingPathComponent(name), options: .atomic)
        }
        for name in writing.gone { try? FileManager.default.removeItem(at: folder.appendingPathComponent(name)) }
    }

    // MARK: Versions

    static let versionsFolder = "versions"

    /// Where a version keeps the design as it was (`VersionKeeping.pack`).
    static func versionFile(_ id: UUID, of design: URL) -> URL {
        design.appendingPathComponent(versionsFolder, isDirectory: true).appendingPathComponent("\(id.uuidString).lzfse")
    }

    static func versionList(at file: URL) -> [DesignVersion] {
        guard let data = try? Data(contentsOf: file) else { return [] }
        return VersionKeeping.list(from: data)
    }

    /// The list of versions that the computer with `replica` writes: in a design shared through
    /// its folder, one of its own in its folder of files; otherwise the design's.
    static func versionIndex(of design: URL, replica: String) -> URL {
        isShared(design) ? folder(of: replica, in: design).appendingPathComponent(versionsFile)
            : design.appendingPathComponent(versionsFolder, isDirectory: true).appendingPathComponent("index.json")
    }

    /// The design's versions as the computer with `replica` has them: its own list, and in a
    /// design shared through its folder, every version anyone else named and shared.
    static func versions(of design: URL, replica: String) -> [DesignVersion] {
        let shared = design.appendingPathComponent(versionsFolder, isDirectory: true).appendingPathComponent("index.json")
        guard isShared(design) else { return versionList(at: shared) }
        let fm = FileManager.default
        let mine = versionIndex(of: design, replica: replica)
        let others = ((try? fm.contentsOfDirectory(at: people(of: design), includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? [])
            .filter { $0.lastPathComponent != replica }
            .map { $0.appendingPathComponent(versionsFile) }
            .filter { fm.fileExists(atPath: $0.path) }
        var out = versionList(at: mine)
        // The design's versions from before it was shared through its folder are the first
        // computer's to share it, to keep on as its own.
        if !fm.fileExists(atPath: mine.path), others.isEmpty { out = versionList(at: shared) }
        var at: [UUID: Int] = [:]
        for (i, v) in out.enumerated() { at[v.id] = i }
        for file in others {
            for v in versionList(at: file) where v.isNamed && v.shared == true {
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

    /// The pictures folder of a design's package (`DesignFile.imagesFolder`).
    private static let imagesFolder = "images"
}
