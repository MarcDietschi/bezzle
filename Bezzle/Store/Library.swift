import AppKit
import Observation

/// Where designs live: new ones go in Documents › Bezzle, and any opened from elsewhere are
/// remembered, so the home screen can show them all, latest first.
@Observable
final class Library {
    static let shared = Library()

    struct Entry: Identifiable, Equatable {
        var url: URL
        var modified: Date
        var id: URL { url }
        var name: String { url.deletingPathExtension().lastPathComponent }
    }

    private(set) var entries: [Entry] = []

    /// Debug and test runs keep their designs somewhere of their own, never among the user's.
    let folder: URL = {
        if let path = ProcessInfo.processInfo.environment["BEZZLE_LIBRARY"] {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        if Library.isolated {
            return FileManager.default.temporaryDirectory.appendingPathComponent("BezzleTests", isDirectory: true)
        }
        return Library.documents.appendingPathComponent("Bezzle", isDirectory: true)
    }()

    private static var documents: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0] }

    /// The app was called Vellum before. The first time it starts as Bezzle, Documents › Vellum
    /// becomes Documents › Bezzle, and the settings kept under the old name come across.
    static func moveInFromVellum() {
        guard !isolated else { return }
        moveDesigns(from: documents.appendingPathComponent("Vellum", isDirectory: true),
                    to: documents.appendingPathComponent("Bezzle", isDirectory: true))
        let defaults = UserDefaults.standard
        let key = "settingsFromVellum"
        guard let id = Bundle.main.bundleIdentifier, !defaults.bool(forKey: key),
              let old = defaults.persistentDomain(forName: "com.erik.Vellum") else { return }
        // Anything already set under the new name wins.
        let current = defaults.persistentDomain(forName: id) ?? [:]
        defaults.setPersistentDomain(old.merging(current) { $1 }.merging([key: true]) { $1 }, forName: id)
    }

    /// Moves an old library folder to where the library now is, its designs renamed to the new
    /// extension, unless a library is there already.
    static func moveDesigns(from old: URL, to new: URL) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: old.path), !fm.fileExists(atPath: new.path) else { return }
        do {
            try fm.moveItem(at: old, to: new)
        } catch {
            NSLog("Bezzle could not move %@ to %@: %@", old.path, new.path, error.localizedDescription)
            return
        }
        for url in (try? fm.contentsOfDirectory(at: new, includingPropertiesForKeys: nil)) ?? []
        where url.pathExtension == BezzleDocument.oldFileExtension {
            let renamed = url.deletingPathExtension().appendingPathExtension(BezzleDocument.fileExtension)
            if !fm.fileExists(atPath: renamed.path) { try? fm.moveItem(at: url, to: renamed) }
        }
    }

    /// Unit tests and debug runs with a library of their own also keep their own list of recent designs.
    private static var isolated: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil || ProcessInfo.processInfo.environment["BEZZLE_LIBRARY"] != nil
    }

    /// Settings and remembered choices, kept apart from the user's own for test and debug runs.
    static let settings: UserDefaults = isolated ? UserDefaults(suiteName: "com.erik.Bezzle.tests") ?? .standard : .standard
    private var defaults: UserDefaults { Library.settings }
    private let recentsKey = "recentDesigns"

    private init() {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        refresh()
    }

    /// Reads the folder and the remembered designs again.
    func refresh() {
        let fm = FileManager.default
        var urls = Set((try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey]))?
            .filter { BezzleDocument.fileExtensions.contains($0.pathExtension) }.map(\.standardizedFileURL) ?? [])
        for path in defaults.stringArray(forKey: recentsKey) ?? [] where fm.fileExists(atPath: path) {
            urls.insert(URL(fileURLWithPath: path).standardizedFileURL)
        }
        entries = urls.map { url in
            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            return Entry(url: url, modified: date)
        }.sorted { $0.modified > $1.modified }
    }

    /// A design was saved or opened: it moves to the front.
    func touched(_ url: URL) {
        remember(url)
        if let i = entries.firstIndex(where: { $0.url == url.standardizedFileURL }) {
            entries[i].modified = Date()
            entries.sort { $0.modified > $1.modified }
        } else {
            refresh()
        }
    }

    func renamed(from old: URL, to new: URL) {
        var paths = defaults.stringArray(forKey: recentsKey) ?? []
        paths.removeAll { $0 == old.standardizedFileURL.path }
        defaults.set(paths, forKey: recentsKey)
        remember(new)
        refresh()
    }

    private func remember(_ url: URL) {
        let path = url.standardizedFileURL.path
        guard !path.hasPrefix(folder.standardizedFileURL.path + "/") else { return }
        var paths = defaults.stringArray(forKey: recentsKey) ?? []
        paths.removeAll { $0 == path }
        paths.insert(path, at: 0)
        defaults.set(Array(paths.prefix(40)), forKey: recentsKey)
    }

    /// Takes a design off the home screen; one in the Bezzle folder goes to the Trash.
    func remove(_ url: URL) {
        let path = url.standardizedFileURL.path
        if path.hasPrefix(folder.standardizedFileURL.path + "/") {
            NSWorkspace.shared.recycle([url])
        }
        var paths = defaults.stringArray(forKey: recentsKey) ?? []
        paths.removeAll { $0 == path }
        defaults.set(paths, forKey: recentsKey)
        entries.removeAll { $0.url == url.standardizedFileURL }
    }

    /// A file name in `folder` that is not taken yet: "Untitled", then "Untitled 2"…
    func freeURL(named name: String, in folder: URL? = nil) -> URL {
        let dir = folder ?? self.folder
        var candidate = dir.appendingPathComponent(name).appendingPathExtension(BezzleDocument.fileExtension)
        var i = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = dir.appendingPathComponent("\(name) \(i)").appendingPathExtension(BezzleDocument.fileExtension)
            i += 1
        }
        return candidate
    }

    /// Makes a new design on disk, with one artboard of `size` if given, and returns where it is.
    func create(artboard size: CGSize?, name: String? = nil) -> URL? {
        var doc = BezzleDocument()
        if let size {
            doc.nodes = [Node(kind: .artboard, name: name ?? "Artboard", frame: CGRect(origin: .zero, size: size))]
        }
        let url = freeURL(named: "Untitled")
        do {
            try DesignFile.write(doc, to: url)
            refresh()
            return url
        } catch {
            NSLog("Bezzle could not create %@: %@", url.path, error.localizedDescription)
            return nil
        }
    }

    /// Makes a copy of a design next to it.
    func duplicate(_ url: URL) {
        let target = freeURL(named: url.deletingPathExtension().lastPathComponent + " copy", in: url.deletingLastPathComponent())
        try? FileManager.default.copyItem(at: url, to: target)
        remember(target)
        refresh()
    }

    // MARK: Thumbnails

    private var thumbnails: [URL: (Date, CGImage?)] = [:]

    /// Whether the home screen is showing. Thumbnails are only made for it, and a design being
    /// worked on, saved every moment, has its thumbnail made again at most every few seconds:
    /// for a large design, making one takes a while.
    var homeShowing = false
    @ObservationIgnored private var madeAt: [URL: Date] = [:]

    func thumbnail(for entry: Entry, size: CGSize) -> CGImage? {
        if let (date, image) = thumbnails[entry.url], date == entry.modified { return image }
        if let (_, image) = thumbnails[entry.url], !homeShowing || Date().timeIntervalSince(madeAt[entry.url] ?? .distantPast) < 10 {
            return image
        }
        madeAt[entry.url] = Date()
        let image = (try? DesignFile.read(entry.url))
            .flatMap { Renderer.thumbnail(of: $0, size: size, assets: Assets(design: entry.url)) }
        thumbnails[entry.url] = (entry.modified, image)
        return image
    }
}

/// Artboard sizes to start from.
struct Preset: Identifiable, Hashable {
    let name: String
    let size: CGSize
    var id: String { name }

    static let all: [Preset] = [
        Preset(name: "Phone", size: CGSize(width: 393, height: 852)),
        Preset(name: "Phone, large", size: CGSize(width: 440, height: 956)),
        Preset(name: "Tablet", size: CGSize(width: 834, height: 1194)),
        Preset(name: "Laptop", size: CGSize(width: 1440, height: 900)),
        Preset(name: "Desktop", size: CGSize(width: 1920, height: 1080)),
        Preset(name: "Watch", size: CGSize(width: 208, height: 248)),
        Preset(name: "Social post", size: CGSize(width: 1080, height: 1080)),
        Preset(name: "Story", size: CGSize(width: 1080, height: 1920)),
        Preset(name: "A4", size: CGSize(width: 595, height: 842)),
    ]
}
