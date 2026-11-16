import Foundation

/// Copies of a design that a sync service made beside it (iCloud Drive, Google Drive and the like),
/// as such a service keeps a design written on two computers at once: "Poster 2", as iCloud Drive
/// names them, or "Poster (1)". Everyone's changes are files of their own in a design
/// (`FolderShare`), so such a copy is taken back into the design without losing anything of
/// either, and put away. Shared by the Mac's `FolderSync` and Windows' `FolderCopy`, which say
/// whether the folder is one a service keeps in step, how a design is held while it is written
/// (`holding`: the Mac's file coordination), and where a copy is put away (`discard`: the Trash,
/// the Recycle Bin).
nonisolated extension FolderShare {
    /// The copies the folder's service made beside the design at `design`: in the same room, and
    /// holding someone's changes the design does not have yet. A copy made in the Finder or
    /// Explorer and never opened is older than the design and brings nothing; one opened has a
    /// room of its own. Either is left as it is.
    ///
    /// The same room is the folder's, or the link's: a design shared by link whose link was opened
    /// on a computer that had it in its designs folder already, through the service, was made
    /// again beside it as "Poster 2", with a folder room of its own.
    static func copiesFromTheService(of design: URL) -> [URL] {
        guard isFolder(design) else { return [] }
        let seed = room(of: design)?.seed, secret = linkSecret(of: design)
        guard seed != nil || secret != nil else { return [] }
        let here = design.standardizedFileURL.path
        let beside = (try? FileManager.default.contentsOfDirectory(at: design.deletingLastPathComponent(), includingPropertiesForKeys: nil,
                                                                  options: [.skipsHiddenFiles])) ?? []
        return beside.filter { url in
            guard url.standardizedFileURL.path != here, url.pathExtension.lowercased() == "bezzle",
                  numberedCopy(url.lastPathComponent) == design.lastPathComponent, isFolder(url) else { return false }
            let sameRoom = (seed != nil && room(of: url)?.seed == seed) || (secret != nil && linkSecret(of: url) == secret)
            return sameRoom && !newParts(in: url, missingFrom: design).isEmpty
        }
    }

    /// The secret of the link the design is shared by, if it is.
    static func linkSecret(of design: URL) -> String? {
        let file = sharing(of: design).appendingPathComponent(linkFile)
        guard let link = (try? Data(contentsOf: file)).flatMap({ decode(ShareLink.self, from: $0) }), !link.secret.isEmpty else { return nil }
        return link.secret
    }

    /// Where a design keeps the link it is shared by, in its sharing folder (`SharingFiles`).
    static let linkFile = "share.json"

    /// The name a sync service gave a second file or folder of the same name, as it does when two
    /// computers write one at once: "Poster 2.bezzle" as macOS names it on a Mac, "Poster
    /// (1).bezzle" as Google Drive, OneDrive and Windows do. Returns the name it stands for
    /// ("Poster.bezzle"); nil for any other.
    static func numberedCopy(_ name: String) -> String? {
        let dot = name.lastIndex(of: ".").flatMap { $0 == name.startIndex ? nil : $0 }
        let stem = dot.map { String(name[..<$0]) } ?? name, ext = dot.map { String(name[$0...]) } ?? ""
        guard let space = stem.lastIndex(of: " ") else { return nil }
        var number = stem[stem.index(after: space)...]
        if number.hasPrefix("("), number.hasSuffix(")") { number = number.dropFirst().dropLast() }
        guard !number.isEmpty, number.count <= 3, number.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        let base = stem[..<space]
        guard !base.isEmpty else { return nil }
        return base + ext
    }

    /// Everyone's files of changes in `copy` that `design` does not have, by where each is.
    static func newParts(in copy: URL, missingFrom design: URL) -> [URL] {
        let fm = FileManager.default
        var found: [URL] = []
        for person in contents(of: people(of: copy)) where isFolder(person) {
            let theirs = folder(of: person.lastPathComponent, in: design)
            for file in contents(of: person)
            where Part(fileName: file.lastPathComponent) != nil && !fm.fileExists(atPath: theirs.appendingPathComponent(file.lastPathComponent).path) {
                found.append(file)
            }
        }
        return found
    }

    /// Takes what a copy the folder's service made holds into the design: everyone's files of
    /// changes it lacks, the newer of anyone's own other files (who they are, their versions'
    /// list), its pictures and its versions; then the copy is put away (`discard`). Read again,
    /// the design has everything both had. Each is held (`holding`) while it is written or put away.
    static func fold(_ copy: URL, into design: URL,
                     holding: (URL, () throws -> Void) throws -> Void = { _, write in try write() },
                     discard: (URL) throws -> Void) throws {
        let fm = FileManager.default
        func modified(_ url: URL) -> Date {
            (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
        }
        /// A folder in the design while it is there, never the design made anew.
        func makeFolder(_ folder: URL) throws {
            guard isFolder(design) else { throw CocoaError(.fileNoSuchFile) }
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        try holding(design) {
            for person in contents(of: people(of: copy)) where isFolder(person) {
                let into = folder(of: person.lastPathComponent, in: design)
                for file in contents(of: person) {
                    let target = into.appendingPathComponent(file.lastPathComponent)
                    if !fm.fileExists(atPath: target.path) {
                        try makeFolder(into)
                        try fm.copyItem(at: file, to: target)
                    } else if Part(fileName: file.lastPathComponent) == nil, modified(file) > modified(target) {
                        // Parts never change once written; who someone is and their versions do.
                        try fm.removeItem(at: target)
                        try fm.copyItem(at: file, to: target)
                    }
                }
            }
            for kind in ["images", versionsFolder] {
                let into = design.appendingPathComponent(kind, isDirectory: true)
                for file in contents(of: copy.appendingPathComponent(kind, isDirectory: true))
                where !fm.fileExists(atPath: into.appendingPathComponent(file.lastPathComponent).path) {
                    try makeFolder(into)
                    try fm.copyItem(at: file, to: into.appendingPathComponent(file.lastPathComponent))
                }
            }
        }
        try withoutActuallyEscaping(discard) { discard in try holding(copy) { try discard(copy) } }
    }

    // MARK: Copies inside a design

    /// What a sync service that keeps each file of a design as an item of its own (Google Drive,
    /// OneDrive, Dropbox) left in it as two computers wrote the same name: the same picture or
    /// version taken from the relay on each ("photo (1).jpg", "photo 2.jpg"), the design's own
    /// file written on both at once ("document 2.json"), a folder made on both ("images 2").
    /// Each is taken back in, so that the design is as one computer would have it:
    ///
    /// - A copy the same as its file, byte for byte, is deleted; a picture the design shows by the
    ///   copy's own name (`using`) is left as it is.
    /// - A second copy of the design's file, its Finder picture or its room is put away
    ///   (`discard`), as the design is made from everyone's parts; of two rooms, the one made
    ///   first is kept, as every computer keeps the same.
    /// - A second folder's files go into the folder, then it is deleted.
    /// - A copy whose file is gone takes its name.
    ///
    /// Anything else that differs is left as it is. Each is held (`holding`) while it is changed.
    /// Returns what was taken in, by path inside the design.
    @discardableResult
    static func foldCopiesInside(_ design: URL, using: Set<String> = [],
                                 holding: (URL, () throws -> Void) throws -> Void = { _, write in try write() },
                                 discard: (URL) throws -> Void) -> [String] {
        guard isFolder(design), hasNumberedCopies(in: design, design: design, using: using) else { return [] }
        var taken: [String] = []
        func inside(_ url: URL) -> String { String(url.standardizedFileURL.path.dropFirst(design.standardizedFileURL.path.count + 1)) }
        do {
            try withoutActuallyEscaping(discard) { discard in
                try holding(design) {
                    try foldCopies(in: design, design: design, using: using, discard: discard) { taken.append(inside($0)) }
                }
            }
        } catch {
            // What was not taken in is looked at again next time.
        }
        return taken
    }

    /// Whether anything in `folder`, or in a folder inside it, has a name a service gives a second
    /// one; looked through without holding the design, as nearly always there is none.
    private static func hasNumberedCopies(in folder: URL, design: URL, using: Set<String>) -> Bool {
        let images = design.appendingPathComponent("images", isDirectory: true).standardizedFileURL.path
        let inImages = folder.standardizedFileURL.path == images
        for item in contents(of: folder) {
            if numberedCopy(item.lastPathComponent) != nil, !(inImages && using.contains(item.lastPathComponent)) { return true }
            if isFolder(item), hasNumberedCopies(in: item, design: design, using: using) { return true }
        }
        return false
    }

    /// Takes in the copies in `folder`, and in every folder inside it.
    private static func foldCopies(in folder: URL, design: URL, using: Set<String>, discard: (URL) throws -> Void, took: (URL) -> Void) throws {
        let fm = FileManager.default
        let images = design.appendingPathComponent("images", isDirectory: true).standardizedFileURL.path
        let inImages = folder.standardizedFileURL.path == images
        for copy in contents(of: folder) {
            guard let name = numberedCopy(copy.lastPathComponent) else { continue }
            if inImages, using.contains(copy.lastPathComponent) { continue }
            let target = folder.appendingPathComponent(name)
            let copyIsFolder = isFolder(copy)
            if !fm.fileExists(atPath: target.path) {
                // Its first is gone, or never came: it is the one now.
                try fm.moveItem(at: copy, to: target)
            } else if copyIsFolder != isFolder(target) {
                continue
            } else if copyIsFolder {
                try merge(copy, into: target)
            } else if fm.contentsEqual(atPath: copy.path, andPath: target.path) {
                try fm.removeItem(at: copy)
            } else if folder.standardizedFileURL.path == design.standardizedFileURL.path, name == "document.json", isShared(design) {
                // Written on two computers at once; the design is made from everyone's parts.
                try discard(copy)
            } else if folder.lastPathComponent == "QuickLook" {
                // Only the Finder's picture of the design, made again with the next change.
                try fm.removeItem(at: copy)
            } else if name == roomFile, folder.lastPathComponent == sharingFolder {
                // Two computers each began a room: everyone keeps the one made first.
                let mine = (try? Data(contentsOf: target)).flatMap { decode(Room.self, from: $0) }
                let theirs = (try? Data(contentsOf: copy)).flatMap { decode(Room.self, from: $0) }
                if let theirs, theirs.isValid, mine.map({ !$0.isValid || theirs.made < $0.made || (theirs.made == $0.made && theirs.seed < $0.seed) }) ?? true {
                    try fm.removeItem(at: target)
                    try fm.moveItem(at: copy, to: target)
                } else {
                    try discard(copy)
                }
            } else {
                continue
            }
            took(copy)
        }
        for sub in contents(of: folder) where isFolder(sub) && numberedCopy(sub.lastPathComponent) == nil {
            try foldCopies(in: sub, design: design, using: using, discard: discard, took: took)
        }
    }

    /// Moves what a second folder of the same name holds into the first, then deletes it: files
    /// the first lacks go in, the same ones are deleted, folders are merged in turn. Of a list both
    /// have that differs, as of who someone is or their versions, the newer stays; parts and
    /// pictures never differ under one name, and one that does is left in the second folder.
    private static func merge(_ copy: URL, into target: URL) throws {
        let fm = FileManager.default
        func modified(_ url: URL) -> Date {
            (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
        }
        for file in contents(of: copy) {
            let into = target.appendingPathComponent(file.lastPathComponent)
            if !fm.fileExists(atPath: into.path) {
                try fm.moveItem(at: file, to: into)
            } else if isFolder(file), isFolder(into) {
                try merge(file, into: into)
            } else if isFolder(file) || isFolder(into) {
                continue
            } else if fm.contentsEqual(atPath: file.path, andPath: into.path) {
                try fm.removeItem(at: file)
            } else if file.pathExtension == "json" {
                if modified(file) > modified(into) {
                    try fm.removeItem(at: into)
                    try fm.moveItem(at: file, to: into)
                } else {
                    try fm.removeItem(at: file)
                }
            }
        }
        if contents(of: copy).isEmpty { try fm.removeItem(at: copy) }
    }

    private static func isFolder(_ url: URL) -> Bool {
        var folder: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &folder) && folder.boolValue
    }

    private static func contents(of folder: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles])) ?? []
    }
}
