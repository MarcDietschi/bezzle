import Foundation
import CryptoKit

/// What came to a design in a synced folder from elsewhere than its folder: the pictures and named
/// versions of someone sharing it by link, fetched from the relay. Shared by the Mac's `Arrivals`
/// and Bezzle for Windows, which say where they are kept (`root`, in the computer's own caches)
/// and how a design is held while they are written into it.
///
/// A folder's service that keeps each file of a design as an item of its own, as Google Drive
/// does, keeps every file written under a name as one more item, and the computer that made a
/// picture or a version writes it into the design itself. Written by every computer that had the
/// design open as well, one picture was kept five times ("photo (1).jpg", "photo 2.jpg",
/// 2026-11-16, in a design three Macs had open). To iCloud Drive, writing it at all is writing the
/// design, which only the computer changing it does. So a computer keeps them beside the design,
/// outside the folder, and shows them from there until the folder brings them. One the folder has
/// not brought after a while goes into the design with this computer's next change of its own
/// (`settle`), as one from someone who has the design by link alone never comes through the folder.
nonisolated extension FolderShare {
    struct Arrivals: Sendable {
        /// Where every design's are kept, in the computer's caches: what is here can be fetched again.
        let root: URL

        init(root: URL) { self.root = root }

        /// The design's own, by where the design is.
        func folder(of design: URL) -> URL {
            let hash = SHA256.hash(data: Data(design.standardizedFileURL.path.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
            return root.appendingPathComponent(hash, isDirectory: true)
        }

        /// Its pictures, by the names the design shows them by.
        func images(of design: URL) -> URL { folder(of: design).appendingPathComponent("images", isDirectory: true) }

        /// Its named versions, as the design's versions folder keeps them.
        func versions(of design: URL) -> URL { folder(of: design).appendingPathComponent(versionsFolder, isDirectory: true) }

        func version(_ id: UUID, of design: URL) -> URL { versions(of: design).appendingPathComponent("\(id.uuidString).lzfse") }

        /// Keeps `data` as the picture or version `name` in `kind` (`images(of:)`, `versions(of:)`).
        func keep(_ data: Data, as name: String, in kind: URL) throws {
            try FileManager.default.createDirectory(at: kind, withIntermediateDirectories: true)
            try data.write(to: kind.appendingPathComponent(name), options: .atomic)
        }

        /// Where the design's picture `name` is: in the design, or else beside it while it is on
        /// its way; nil when it is in neither.
        func picture(_ name: String, of design: URL) -> URL? {
            let fm = FileManager.default
            let inDesign = design.appendingPathComponent("images", isDirectory: true).appendingPathComponent(name)
            if fm.fileExists(atPath: inDesign.path) { return inDesign }
            let waiting = images(of: design).appendingPathComponent(name)
            return fm.fileExists(atPath: waiting.path) ? waiting : nil
        }

        /// Forgets what the folder brought, and writes into the design what it has not brought
        /// `grace` after it came, each held (`holding`) while it is written. On the queue the
        /// design is saved on, with this computer's own changes.
        func settle(_ design: URL, grace: TimeInterval, now: Date = Date(),
                    holding: (URL, () throws -> Void) throws -> Void = { _, write in try write() }) {
            let fm = FileManager.default
            for (aside, kind) in [(images(of: design), "images"), (versions(of: design), versionsFolder)] {
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
                        try holding(design) {
                            // Inside the design while it is there, never its package made anew.
                            var folder: ObjCBool = false
                            guard fm.fileExists(atPath: design.path, isDirectory: &folder), folder.boolValue else { throw CocoaError(.fileNoSuchFile) }
                            try fm.createDirectory(at: into, withIntermediateDirectories: true)
                            try fm.copyItem(at: file, to: target)
                        }
                        try? fm.removeItem(at: file)
                    } catch {
                        // Written with the next change made here.
                    }
                }
            }
            if ((try? fm.contentsOfDirectory(atPath: images(of: design).path)) ?? []).isEmpty,
               ((try? fm.contentsOfDirectory(atPath: versions(of: design).path)) ?? []).isEmpty {
                try? fm.removeItem(at: folder(of: design))
            }
        }

        /// Pictures the folder brought: what was kept of them beside the design is not needed now.
        func arrived(pictures names: [String], of design: URL) {
            let aside = images(of: design)
            for name in names { try? FileManager.default.removeItem(at: aside.appendingPathComponent(name)) }
        }
    }
}
