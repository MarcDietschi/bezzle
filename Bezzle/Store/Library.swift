import AppKit
import CryptoKit
import Observation
import UniformTypeIdentifiers

/// Where designs live: new ones go in Documents › Bezzle, and any opened from elsewhere are
/// remembered, so the home screen can show them all, latest first.
@Observable
final class Library {
    static let shared = Library()

    struct Entry: Identifiable, Equatable {
        var url: URL
        var modified: Date
        /// How it is shared, if it is.
        var sharing: SharingMark?
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
            return Entry(url: url, modified: date, sharing: SharingFiles.link(of: url)?.mark)
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
            doc.nodes = [Node(kind: .artboard, name: name ?? String(localized: "Artboard"), frame: CGRect(origin: .zero, size: size))]
        }
        let url = freeURL(named: String(localized: "Untitled"))
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
        let target = freeURL(named: String(localized: "\(url.deletingPathExtension().lastPathComponent) copy"), in: url.deletingLastPathComponent())
        try? FileManager.default.copyItem(at: url, to: target)
        // A copy is a design of its own, never shared.
        SharingFiles.unlink(target)
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
    /// Designs whose thumbnails are being made.
    @ObservationIgnored private var making: Set<URL> = []

    /// The design's thumbnail; nil for an empty design, or while it is first made. A thumbnail is
    /// made in the background, as reading a large design and its pictures takes seconds, and
    /// kept on disk, so the home screen has it at once the next time.
    func thumbnail(for entry: Entry, size: CGSize) -> CGImage? {
        if let (date, image) = thumbnails[entry.url], date == entry.modified { return image }
        if let (_, image) = thumbnails[entry.url], !homeShowing || Date().timeIntervalSince(madeAt[entry.url] ?? .distantPast) < 10 {
            return image
        }
        if !making.contains(entry.url) {
            if let kept = Self.keptThumbnail(entry) {
                thumbnails[entry.url] = (entry.modified, kept)
                return kept
            }
            makeThumbnail(entry, size: size)
        }
        return thumbnails[entry.url]?.1
    }

    /// Whether the design's thumbnail is being made for the first time, so there is none to show yet.
    func isMakingThumbnail(for entry: Entry) -> Bool { making.contains(entry.url) && thumbnails[entry.url] == nil }

    private func makeThumbnail(_ entry: Entry, size: CGSize) {
        let url = entry.url, modified = entry.modified
        making.insert(url)
        madeAt[url] = Date()
        Task.detached(priority: .userInitiated) {
            let doc = try? DesignFile.read(url)
            let assets = doc.map { Assets.previews(Self.pictureSizes(in: $0, thumbnail: size, scale: 2), design: url) }
            await Library.shared.finishThumbnail(url, modified: modified, doc: doc, assets: assets, size: size)
        }
    }

    private func finishThumbnail(_ url: URL, modified: Date, doc: BezzleDocument?, assets: Assets?, size: CGSize) {
        let image = doc.flatMap { Renderer.thumbnail(of: $0, size: size, assets: assets) }
        making.remove(url)
        thumbnails[url] = (modified, image)
        if let image { Self.keep(image, for: url, modified: modified) }
    }

    /// How many pixels each picture in the design takes along its longer side when the whole
    /// design is drawn as a thumbnail of `size`. The thumbnail draws the canvas at one scale,
    /// and nothing in a design is scaled on the way down, so a layer's frame says it all.
    nonisolated static func pictureSizes(in doc: BezzleDocument, thumbnail size: CGSize, scale: CGFloat) -> [String: Int] {
        guard let bounds = doc.contentBounds, bounds.width > 0, bounds.height > 0 else { return [:] }
        let fit = min(size.width / bounds.width, size.height / bounds.height) * 0.86 * scale
        var sizes: [String: Int] = [:]
        func visit(_ n: Node) {
            if let image = n.fill.image, image.size.width > 0, image.size.height > 0 {
                // Covering its layer, it may reach past it the long way.
                let cover = max(n.frame.width / image.size.width, n.frame.height / image.size.height) * max(image.scale, 1)
                let pixels = Int((max(image.size.width, image.size.height) * cover * fit).rounded(.up))
                sizes[image.shown] = max(sizes[image.shown] ?? 0, min(max(pixels, 16), 2048))
            }
            n.children.forEach(visit)
            n.mask?.forEach(visit)
        }
        doc.nodes.forEach(visit)
        return sizes
    }

    // Kept on disk, in the caches folder, under the design's path and when it last changed.

    private nonisolated static let thumbnailFolder: URL = {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return caches.appendingPathComponent(Bundle.main.bundleIdentifier ?? "Bezzle", isDirectory: true)
            .appendingPathComponent("Thumbnails", isDirectory: true)
    }()

    private nonisolated static func thumbnailName(_ url: URL) -> String {
        Insecure.SHA1.hash(data: Data(url.standardizedFileURL.path.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private nonisolated static func thumbnailFile(_ url: URL, modified: Date) -> URL {
        thumbnailFolder.appendingPathComponent("\(thumbnailName(url))-\(Int64(modified.timeIntervalSince1970 * 1000)).png")
    }

    private static func keptThumbnail(_ entry: Entry) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(thumbnailFile(entry.url, modified: entry.modified) as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    /// Writes it in the background, in place of any made before.
    private static func keep(_ image: CGImage, for url: URL, modified: Date) {
        let file = thumbnailFile(url, modified: modified), name = thumbnailName(url)
        Task.detached(priority: .utility) {
            let fm = FileManager.default
            try? fm.createDirectory(at: thumbnailFolder, withIntermediateDirectories: true)
            for old in (try? fm.contentsOfDirectory(at: thumbnailFolder, includingPropertiesForKeys: nil)) ?? []
            where old.lastPathComponent.hasPrefix(name + "-") {
                try? fm.removeItem(at: old)
            }
            guard let out = CGImageDestinationCreateWithURL(file as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
            CGImageDestinationAddImage(out, image, nil)
            CGImageDestinationFinalize(out)
        }
    }
}

/// Artboard sizes to start from.
struct Preset: Identifiable, Hashable {
    /// Shown in the user's language.
    let title: LocalizedStringResource
    let size: CGSize
    /// The English name, which the AI is told and which stays the same whatever the language.
    var name: String { title.key }
    var id: String { name }

    static func == (a: Preset, b: Preset) -> Bool { a.name == b.name && a.size == b.size }
    func hash(into hasher: inout Hasher) { hasher.combine(name) }

    static let all: [Preset] = [
        Preset(title: "Phone", size: CGSize(width: 393, height: 852)),
        Preset(title: "Phone, large", size: CGSize(width: 440, height: 956)),
        Preset(title: "Tablet", size: CGSize(width: 834, height: 1194)),
        Preset(title: "Laptop", size: CGSize(width: 1440, height: 900)),
        Preset(title: "Desktop", size: CGSize(width: 1920, height: 1080)),
        Preset(title: "Watch", size: CGSize(width: 208, height: 248)),
        Preset(title: "Social post", size: CGSize(width: 1080, height: 1080)),
        Preset(title: "Story", size: CGSize(width: 1080, height: 1920)),
        Preset(title: "A4", size: CGSize(width: 595, height: 842)),
    ]
}
