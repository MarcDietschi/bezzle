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
    static func copiesFromTheService(of design: URL) -> [URL] {
        guard isFolder(design), let seed = room(of: design)?.seed else { return [] }
        let base = design.deletingPathExtension().lastPathComponent
        let here = design.standardizedFileURL.path
        let beside = (try? FileManager.default.contentsOfDirectory(at: design.deletingLastPathComponent(), includingPropertiesForKeys: nil,
                                                                  options: [.skipsHiddenFiles])) ?? []
        return beside.filter { url in
            guard url.standardizedFileURL.path != here, url.pathExtension.lowercased() == "bezzle" else { return false }
            let name = url.deletingPathExtension().lastPathComponent
            guard name.hasPrefix(base + " ") else { return false }
            var number = name.dropFirst(base.count + 1)
            if number.hasPrefix("("), number.hasSuffix(")") { number = number.dropFirst().dropLast() }
            guard !number.isEmpty, number.allSatisfy({ $0.isASCII && $0.isNumber }) else { return false }
            return isFolder(url) && room(of: url)?.seed == seed && !newParts(in: url, missingFrom: design).isEmpty
        }
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

    private static func isFolder(_ url: URL) -> Bool {
        var folder: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &folder) && folder.boolValue
    }

    private static func contents(of folder: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles])) ?? []
    }
}
