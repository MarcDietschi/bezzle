import Foundation

/// What came to a design in a synced folder from elsewhere than its folder, kept on this Mac beside
/// the design until the folder brings it (`FolderShare.Arrivals`, which says why): the pictures
/// and named versions of someone sharing it by link, fetched from the relay.
nonisolated enum Arrivals {
    /// Where every design's are kept, in this Mac's caches.
    static let kept = FolderShare.Arrivals(root: {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return caches.appendingPathComponent(Bundle.main.bundleIdentifier ?? "Bezzle", isDirectory: true)
            .appendingPathComponent("Arrivals", isDirectory: true)
    }())

    /// How long one waits for the folder to bring it before this Mac writes it into the design.
    nonisolated(unsafe) static var grace: TimeInterval = 120

    static func folder(of design: URL) -> URL { kept.folder(of: design) }

    static func images(of design: URL) -> URL { kept.images(of: design) }

    static func version(_ id: UUID, of design: URL) -> URL { kept.version(id, of: design) }

    static func versions(of design: URL) -> URL { kept.versions(of: design) }

    static func keep(_ data: Data, as name: String, in kind: URL) throws { try kept.keep(data, as: name, in: kind) }

    /// Whether the design's picture `name` is here, in the design or beside it.
    static func hasPicture(_ name: String, of design: URL) -> Bool { kept.picture(name, of: design) != nil }

    /// Forgets what the folder brought, and writes into the design what it has not brought by now,
    /// `grace` after it came, held by the system's file coordination.
    static func settle(_ design: URL, now: Date = Date()) {
        kept.settle(design, grace: grace, now: now) { url, write in try DesignFile.coordinated(writing: url) { _ in try write() } }
    }

    /// Pictures the folder brought: what was kept of them beside the design is not needed now.
    static func arrived(pictures names: [String], of design: URL) { kept.arrived(pictures: names, of: design) }
}
