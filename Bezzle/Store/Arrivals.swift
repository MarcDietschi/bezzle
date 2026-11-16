import CryptoKit
import Foundation

/// What came to a design in a synced folder from elsewhere than its folder: the pictures and named
/// versions of someone sharing it by link, fetched from the relay or handed over in the live room.
///
/// A folder's service that keeps each file of a design as an item of its own, as Google Drive
/// does, keeps every file written under a name as one more item, and the computer that made a
/// picture or a version writes it into the design itself. Written by every computer that had the
/// design open as well, one picture was kept five times ("photo (1).jpg", "photo 2.jpg", 2026-11-16,
/// in a design three Macs had open). To iCloud Drive, writing it at all is writing the design, which
/// only the computer changing it does. So this Mac keeps them beside the design, outside the
/// folder, and shows them from there until the folder brings them. One the folder has not brought
/// after a while goes into the design with this Mac's next change of its own (`settle`), as one
/// from someone who has the design by link alone never comes through the folder.
nonisolated enum Arrivals {
    /// Where every design's are kept, in this Mac's caches: what is here can always be fetched again.
    static let root: URL = {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return caches.appendingPathComponent(Bundle.main.bundleIdentifier ?? "Bezzle", isDirectory: true)
            .appendingPathComponent("Arrivals", isDirectory: true)
    }()

    /// How long one waits for the folder to bring it before this Mac writes it into the design.
    nonisolated(unsafe) static var grace: TimeInterval = 120

    /// The design's own, by where the design is.
    static func folder(of design: URL) -> URL {
        let hash = SHA256.hash(data: Data(design.standardizedFileURL.path.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
        return root.appendingPathComponent(hash, isDirectory: true)
    }

    /// Its pictures, by the names the design shows them by.
    static func images(of design: URL) -> URL { folder(of: design).appendingPathComponent(DesignFile.imagesFolder, isDirectory: true) }

    /// Its named versions, as the design's versions folder keeps them (`VersionFiles`).
    static func versions(of design: URL) -> URL { folder(of: design).appendingPathComponent(FolderShare.versionsFolder, isDirectory: true) }

    static func version(_ id: UUID, of design: URL) -> URL { versions(of: design).appendingPathComponent("\(id.uuidString).lzfse") }

    /// Keeps `data` as the picture or version `name` in `kind` (`images(of:)`, `versions(of:)`).
    static func keep(_ data: Data, as name: String, in kind: URL) throws {
        try FileManager.default.createDirectory(at: kind, withIntermediateDirectories: true)
        try data.write(to: kind.appendingPathComponent(name), options: .atomic)
    }

    /// Whether the design's picture `name` is here, in the design or beside it.
    static func hasPicture(_ name: String, of design: URL) -> Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: design.appendingPathComponent(DesignFile.imagesFolder).appendingPathComponent(name).path)
            || fm.fileExists(atPath: images(of: design).appendingPathComponent(name).path)
    }

    /// Forgets what the folder brought, and writes into the design what it has not brought by now,
    /// `grace` after it came. On the queue the design is saved on, with this Mac's own changes.
    static func settle(_ design: URL, now: Date = Date()) {
        let fm = FileManager.default
        for (aside, kind) in [(images(of: design), DesignFile.imagesFolder), (versions(of: design), FolderShare.versionsFolder)] {
            let waiting = (try? fm.contentsOfDirectory(at: aside, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles])) ?? []
            let into = design.appendingPathComponent(kind, isDirectory: true)
            for file in waiting {
                let target = into.appendingPathComponent(file.lastPathComponent)
                if fm.fileExists(atPath: target.path) {
                    try? fm.removeItem(at: file)
                    continue
                }
                let came = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? now
                guard now.timeIntervalSince(came) >= grace else { continue }
                do {
                    try DesignFile.coordinated(writing: design) { _ in
                        try DesignFile.makeFolder(into, in: design)
                        try fm.copyItem(at: file, to: target)
                    }
                    try? fm.removeItem(at: file)
                } catch {
                    NSLog("Bezzle could not write %@ into %@: %@", file.lastPathComponent, design.lastPathComponent, error.localizedDescription)
                }
            }
        }
        if ((try? fm.contentsOfDirectory(atPath: images(of: design).path)) ?? []).isEmpty,
           ((try? fm.contentsOfDirectory(atPath: versions(of: design).path)) ?? []).isEmpty {
            try? fm.removeItem(at: folder(of: design))
        }
    }

    /// Pictures the folder brought: what was kept of them beside the design is not needed now.
    static func arrived(pictures names: [String], of design: URL) {
        let aside = images(of: design)
        for name in names { try? FileManager.default.removeItem(at: aside.appendingPathComponent(name)) }
    }
}
