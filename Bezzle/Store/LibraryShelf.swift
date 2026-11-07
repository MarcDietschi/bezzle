import AppKit
import Observation

/// The designs on the home screen as libraries for each other: what each holds that others can
/// take, read from its file away from the main thread, once each time it is saved. See `LibraryLink`.
@MainActor @Observable
final class LibraryShelf {
    static let shared = LibraryShelf()

    /// Every design read so far, in the home screen's order, latest first.
    private(set) var designs: [LibraryContent] = []
    /// News set aside on a design, by the design's file: what it was about and how it was then,
    /// so newer news still shows.
    private(set) var setAside: [String: Set<String>] = [:]
    @ObservationIgnored private var reading = false
    @ObservationIgnored private var again: URL??
    @ObservationIgnored private var waiting: [CheckedContinuation<Void, Never>] = []
    /// Designs that could not be read, and as of when, so they are not read again until they change.
    @ObservationIgnored private var unreadable: [URL: Date] = [:]

    /// Reads the designs that changed since they were last read, all but `except` (the design
    /// asking, which has itself open already).
    func refresh(except: URL? = nil) {
        guard !reading else { again = .some(except); return }
        let entries = Library.shared.entries
        let known = Dictionary(designs.map { ($0.url, $0) }, uniquingKeysWith: { a, _ in a })
        let stale = entries.filter { e in
            !Self.same(e.url, except) && known[e.url]?.modified != e.modified && unreadable[e.url] != e.modified
        }
        let order = entries.map(\.url)
        let present = Set(order)
        guard !stale.isEmpty || known.keys.contains(where: { !present.contains($0) }) else { return }
        reading = true
        let wanted = stale.map { ($0.url, $0.name, $0.modified) }
        Task.detached(priority: .utility) {
            var read: [URL: LibraryContent] = [:]
            for (url, name, modified) in wanted {
                if let content = LibraryContent.read(url, name: name, modified: modified) { read[url] = content }
            }
            await MainActor.run {
                let shelf = LibraryShelf.shared
                var all = Dictionary(shelf.designs.map { ($0.url, $0) }, uniquingKeysWith: { a, _ in a })
                for (url, content) in read { all[url] = content }
                for (url, _, modified) in wanted where read[url] == nil { shelf.unreadable[url] = modified }
                let next = order.compactMap { all[$0] }
                if next != shelf.designs { shelf.designs = next }
                shelf.reading = false
                if let again = shelf.again {
                    shelf.again = nil
                    shelf.refresh(except: again)
                }
                if !shelf.reading {
                    let waiting = shelf.waiting
                    shelf.waiting = []
                    waiting.forEach { $0.resume() }
                }
            }
        }
    }

    /// Reads what changed, as `refresh` does, and returns once it is read.
    func refreshed(except: URL? = nil) async {
        refresh(except: except)
        while reading { await withCheckedContinuation { waiting.append($0) } }
    }

    /// The designs that have components or styles of their own, but the one at `url`.
    func libraries(except url: URL) -> [LibraryContent] {
        designs.filter { !Self.same($0.url, url) && $0.isLibrary }
    }

    func content(_ url: URL) -> LibraryContent? { designs.first { Self.same($0.url, url) } }

    /// Whether two links are to the same design: the home screen's are to its package, as a folder.
    nonisolated static func same(_ a: URL, _ b: URL?) -> Bool {
        guard let b else { return false }
        return a.standardizedFileURL.path == b.standardizedFileURL.path
    }

    /// What has changed in other designs since this one took from them, without what was set aside.
    func news(for doc: BezzleDocument, at url: URL) -> [LibraryNews] {
        let aside = setAside[url.standardizedFileURL.path] ?? []
        return doc.libraryNews(in: designs.filter { !Self.same($0.url, url) }).compactMap { news in
            var n = news
            n.masters.removeAll { aside.contains(Self.key($0, news.prints[$0])) }
            n.styles.removeAll { aside.contains(Self.key($0, news.prints[$0])) }
            return n.count == 0 ? nil : n
        }
    }

    /// Leaves news as it is: it shows again only once there is newer.
    func setAside(_ news: LibraryNews, for url: URL) {
        let keys = (news.masters + news.styles).map { Self.key($0, news.prints[$0]) }
        setAside[url.standardizedFileURL.path, default: []].formUnion(keys)
    }

    private static func key(_ id: UUID, _ print: String?) -> String { "\(id.uuidString)|\(print ?? "")" }
}

// MARK: - Taking from libraries

extension DocumentStore {
    /// Gives the selection a style of another design, which comes into this one with it; with
    /// nothing selected, only brings it in, to use from the design's own styles.
    func use(_ styleID: UUID, of library: LibraryContent) {
        let take = library.taking(style: styleID)
        guard !take.styles.isEmpty else { return }
        let targets = selection
        let open = openAspect?.stylePlace
        edit(targets.isEmpty ? "Add Style" : "Use Style") { $0.use(styleID, taking: take, on: targets, at: open) }
        // On a dark artboard a layer shows the style's dark look; `syncStyles` sees to that.
    }

    /// A style shown on the selection without being given, while the pointer is on it.
    func preview(_ style: Style?) {
        guard let style, !selection.isEmpty else { showPreview("libraryStyle", nil); return }
        let open = openAspect?.stylePlace
        let doc = doc
        showPreview("libraryStyle") { n in
            var shown = style
            shown.look = style.look(dark: doc.isDark(n.id))
            Self.give(shown, to: &n, at: open, dark: false, naming: false)
        }
    }

    /// Where on a layer a style of its kind goes: the place the inspector has open, if it is of
    /// that kind, else the first fill (a text's letters), its type, its first shadow or its
    /// corners. What it goes on is turned on, so it shows.
    static func give(_ style: Style, to n: inout Node, at open: StylePlace?, dark: Bool, naming: Bool = true) {
        n.give(style, at: open, dark: dark, naming: naming)
    }

    /// Brings components and styles taken from another design up to date with it.
    func update(from news: LibraryNews) {
        guard let library = LibraryShelf.shared.content(news.url) else { return }
        bringPictures(library.taking(news.masters))
        showPreview("libraryNews", reshaping: nil)
        edit("Update from Library") { $0.update(from: library, masters: news.masters, styles: news.styles) }
    }

    /// The design as it would be brought up to date, for the canvas to show while the pointer is
    /// on the offer.
    func updating(from news: LibraryNews) -> ((inout BezzleDocument) -> Void)? {
        guard let library = LibraryShelf.shared.content(news.url) else { return nil }
        return { $0.updating(from: library, masters: news.masters, styles: news.styles) }
    }

    /// The copies of the components, and the layers named after the styles, news is about.
    func layers(in news: LibraryNews) -> [UUID] {
        news.masters.flatMap { doc.copies(of: $0).map(\.id) } + news.styles.flatMap { layers(using: $0) }
    }

    /// Copies the pictures components from another design show into this design's package, where
    /// they are not yet.
    func bringPictures(_ take: LibraryTake) {
        guard let from = take.url, !LibraryShelf.same(from, url) else { return }
        let names = take.pictures
        guard !names.isEmpty else { return }
        let source = from.appendingPathComponent(DesignFile.imagesFolder, isDirectory: true)
        let fm = FileManager.default
        let wanted = names.filter { fm.fileExists(atPath: source.appendingPathComponent($0).path) }
        guard !wanted.isEmpty else { return }
        if !DesignFile.isPackage(url) {
            save()
            Self.finishSaving()
            do {
                try DesignFile.makePackage(url)
                becamePackage()
            } catch {
                NSLog("Bezzle could not make %@ a package: %@", url.path, error.localizedDescription)
                return
            }
        }
        let images = url.appendingPathComponent(DesignFile.imagesFolder, isDirectory: true)
        try? fm.createDirectory(at: images, withIntermediateDirectories: true)
        for name in wanted where !fm.fileExists(atPath: images.appendingPathComponent(name).path) {
            do {
                try fm.copyItem(at: source.appendingPathComponent(name), to: images.appendingPathComponent(name))
                assets.arrived(name)
            } catch {
                NSLog("Bezzle could not copy the picture %@ into the design: %@", name, error.localizedDescription)
            }
        }
    }
}
