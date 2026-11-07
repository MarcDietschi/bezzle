import Foundation

/// The files and folders outside its own that Bezzle may use, as its sandbox has it:
/// a design opened from the Finder or the Open panel, the folder chosen in the Export panel.
/// Such a choice lets Bezzle in only until it quits, so a bookmark of each is kept and all are
/// opened again at launch. Everything else then goes on using plain paths, as without a sandbox.
enum FileAccess {
    private static let key = "fileAccess"
    /// Enough for every design on the home screen and every shared one; the oldest go first.
    private static let limit = 200

    private static var entries: [[String: Any]] {
        Library.settings.array(forKey: key) as? [[String: Any]] ?? []
    }

    /// Remembers that Bezzle may use `url`, while it still can.
    static func keep(_ url: URL) {
        guard let bookmark = try? url.bookmarkData(options: .withSecurityScope) else { return }
        let path = url.standardizedFileURL.path
        var kept = entries.filter { $0["path"] as? String != path }
        kept.insert(["path": path, "bookmark": bookmark], at: 0)
        Library.settings.set(Array(kept.prefix(limit)), forKey: key)
    }

    private static var reopened = false

    /// At launch, before anything looks for these files. One that can't be found now, on a disk
    /// that isn't plugged in say, is kept for when it is.
    static func reopen() {
        guard !reopened else { return }
        reopened = true
        var kept = entries
        for (i, entry) in kept.enumerated() {
            guard let data = entry["bookmark"] as? Data else { continue }
            var stale = false
            guard let url = try? URL(resolvingBookmarkData: data, options: [.withSecurityScope, .withoutUI, .withoutMounting],
                                     bookmarkDataIsStale: &stale) else { continue }
            // Open until Bezzle quits.
            _ = url.startAccessingSecurityScopedResource()
            if stale, let fresh = try? url.bookmarkData(options: .withSecurityScope) {
                kept[i] = ["path": url.standardizedFileURL.path, "bookmark": fresh]
            }
        }
        Library.settings.set(kept, forKey: key)
    }
}
